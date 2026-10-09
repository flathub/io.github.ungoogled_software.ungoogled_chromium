#!/bin/bash -ex

# GN's bootstrap must not inherit the SDK compiler/linker flags.
unset CFLAGS CXXFLAGS LDFLAGS

# UGC removes bundled binaries before applying its patches and substitutions.
uc/utils/prune_binaries.py . uc/pruning.list
uc/utils/patches.py apply . uc/patches
uc/utils/domain_substitution.py apply -r uc/domain_regex.list \
    -f uc/domain_substitution.list -c domsubcache.tar.gz .

# Prebuilt compiler paths and flags are supplied by the Flatpak manifest.
# Link the staged binaries after UGC pruning.
tools_dir="$PWD/_build_tools"
ln_overwrite_all() {
    rm -rf "$2"
    mkdir -p "$(dirname "$2")"
    ln -s "$1" "$2"
}
ln_overwrite_all "$tools_dir/llvm" third_party/llvm-build/Release+Asserts
ln_overwrite_all "$tools_dir/rust" third_party/rust-toolchain
ln_overwrite_all "$tools_dir/libclang" third_party/llvm-libclang
ln_overwrite_all /usr/lib/sdk/node24 third_party/node/linux/node-linux-x64
ln_overwrite_all /usr/lib/sdk/openjdk21 third_party/jdk/current
ln_overwrite_all "$tools_dir/clang-format" buildtools/linux64-format/clang-format
ln_overwrite_all /app/lib/sdk/esbuild/bin/esbuild third_party/devtools-frontend/src/third_party/esbuild/esbuild

# tsc resolves symlinks; its declarations must remain inside the source tree.
rm -rf third_party/typescript/linux-amd64/src
mkdir -p third_party/typescript/linux-amd64/src
cp -a "$tools_dir/typescript/." third_party/typescript/linux-amd64/src/

ln -sf /usr/bin/ninja third_party/ninja
ln_overwrite_all /usr/bin/gperf third_party/gperf/cipd/bin/gperf

# UGC disables Google services and PGO; ARM64 uses V4L2 for video decoding.
arch_args=''
case "$FLATPAK_ARCH" in
    x86_64) go_arch=amd64 ;;
    aarch64)
        go_arch=arm64
        arch_args='use_v4l2_codec=true use_vaapi=false use_av1_hw_decoder=true'
        ;;
    *) echo >&2 "Unsupported architecture: $FLATPAK_ARCH"; exit 1 ;;
esac
ln_overwrite_all "$tools_dir/go" "third_party/dawn/tools/golang/linux-$go_arch"

CC="/app/bin/sccache $CC" CXX="/app/bin/sccache $CXX" \
    tools/gn/bootstrap/bootstrap.py -v --no-clean -j"$FLATPAK_BUILDER_N_JOBS" \
    --gn-gen-args="$(cat uc/flags.gn)
        cc_wrapper=\"/app/bin/sccache\"
        symbol_level=0
        use_sysroot=false
        ffmpeg_branding=\"Chrome\"
        is_official_build=true
        link_pulseaudio=true
        proprietary_codecs=true
        rtc_use_pipewire=true
        use_system_libffi=true
        $arch_args
    "

# V8's metagen needs this on both architectures.
mkdir -p buildtools/linux64
ln -sf "$PWD/out/Release/gn" buildtools/linux64/gn
