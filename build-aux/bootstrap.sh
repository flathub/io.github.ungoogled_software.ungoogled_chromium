#!/bin/bash -ex

# Needed to build GN itself.
. /usr/lib/sdk/llvm22/enable.sh

# GN will use these variables to configure its own build, but they introduce
# compat issues w/ Clang and aren't used by Chromium itself anyway, so just
# unset them here.
unset CFLAGS CXXFLAGS LDFLAGS

# Apply ungoogled-chromium: prune the bundled binaries, then apply its patches
# and domain substitution.
uc/utils/prune_binaries.py . uc/pruning.list
uc/utils/patches.py apply . uc/patches
uc/utils/domain_substitution.py apply -r uc/domain_regex.list \
  -f uc/domain_substitution.list -c domsubcache.tar.gz .

ln_overwrite_all() {
  rm -rf "$2"
  mkdir -p "$(dirname "$2")"
  ln -s "$1" "$2"
}

# ungoogled-chromium's pruning removes the bundled toolchain directories, so
# link the staged prebuilt tools into the locations Chromium expects.
tools_dir=$PWD/_build_tools
ln_overwrite_all $tools_dir/llvm third_party/llvm-build/Release+Asserts
ln_overwrite_all $tools_dir/rust third_party/rust-toolchain
ln_overwrite_all $tools_dir/libclang third_party/llvm-libclang
ln_overwrite_all $tools_dir/clang-format buildtools/linux64-format/clang-format

# tsc resolves symlinks, so TypeScript must be copied into the source tree.
rm -rf third_party/typescript/linux-amd64/src
mkdir -p third_party/typescript/linux-amd64/src
cp -a $tools_dir/typescript/. third_party/typescript/linux-amd64/src/

case "$(uname -m)" in
  x86_64) go_arch=amd64 ;;
  aarch64) go_arch=arm64 ;;
esac
ln_overwrite_all $tools_dir/go third_party/dawn/tools/golang/linux-$go_arch

mkdir -p third_party/devtools-frontend/src/third_party/esbuild
ln -sf /app/lib/sdk/esbuild/bin/esbuild \
  third_party/devtools-frontend/src/third_party/esbuild/esbuild

mkdir -p third_party/gperf/cipd/bin
ln -sf /usr/bin/gperf third_party/gperf/cipd/bin/

# Keep the default VA-API support on x86_64 and use V4L2 on aarch64.
arch_args=
if [[ "$(uname -m)" == "aarch64" ]]; then
  arch_args='use_v4l2_codec=true use_vaapi=false use_av1_hw_decoder=true'
fi

# ungoogled-chromium's own GN flags come first; cc_wrapper enables sccache.
tools/gn/bootstrap/bootstrap.py -v --no-clean --gn-gen-args="
    $(cat uc/flags.gn)
    cc_wrapper=\"/app/bin/sccache\"
    use_sysroot=false
    symbol_level=0
    is_official_build=true
    link_pulseaudio=true
    proprietary_codecs=true
    ffmpeg_branding=\"Chrome\"
    rtc_use_pipewire=true
    use_system_libffi=true
    $arch_args
"

# Blink's bindings generator and V8's metagen run //buildtools/linux64/gn, which
# ungoogled-chromium prunes.
mkdir -p buildtools/linux64
ln -sf "$PWD/out/Release/gn" buildtools/linux64/gn
