#!/bin/bash -ex

# Needed to build GN itself.
. /usr/lib/sdk/llvm18/enable.sh

# GN will use these variables to configure its own build, but they introduce
# compat issues w/ Clang and aren't used by Chromium itself anyway, so just
# unset them here.
unset CFLAGS CXXFLAGS LDFLAGS

chrome_pgo_phase=2
# Support the Gentoo Chromium tarballs, which are missing the full GN source.
if [[ ! -f tools/gn/build/gen.py ]]; then
	chrome_pgo_phase=0
	cp -r tools/gn.git/* tools/gn
	cat > tools/gn/bootstrap/last_commit_position.h <<-EOF
	#ifndef OUT_LAST_COMMIT_POSITION_H_
	#define OUT_LAST_COMMIT_POSITION_H_
	#define LAST_COMMIT_POSITION_NUM 1
	#define LAST_COMMIT_POSITION "unknown"
	#endif
	EOF
fi

if [[ -d third_party/llvm-build/Release+Asserts/bin ]]; then
	# The build scripts check that the stamp file is present, so write it out
	# here.
	PYTHONPATH=tools/clang/scripts/ \
		python3 -c 'import update; print(update.PACKAGE_VERSION)' \
		> third_party/llvm-build/Release+Asserts/cr_build_revision
else
	python3 tools/clang/scripts/build.py --disable-asserts --pic \
		--skip-checkout --use-system-cmake --use-system-libxml \
		--host-cc=/usr/lib/sdk/llvm18/bin/clang \
		--host-cxx=/usr/lib/sdk/llvm18/bin/clang++ \
		--target-triple=$(clang -dumpmachine) \
		--without-android --without-fuchsia --without-zstd \
		--with-ml-inliner-model=
fi

cp -r /app/lib/sdk/bindgen bindgen
if [[ -e third_party/rust-toolchain/lib/libclang.so ]]; then
  ln -s "$PWD/third_party/rust-toolchain/lib" -t bindgen
else
  ln -s "$PWD/third_party/llvm-build/Release+Asserts/lib" -t bindgen
fi

# (TODO: enable use_qt in the future?)
mkdir -p out/Release
cp ./uc/src/flags.gn out/Release/args.gn
cat >> out/Release/args.gn <<-EOF
	use_sysroot=false
	use_lld=true
	enable_nacl=false
	blink_symbol_level=0
	use_gnome_keyring=false
	use_pulseaudio=true
	clang_use_chrome_plugins=false
	is_official_build=true
	treat_warnings_as_errors=false
	proprietary_codecs=true
	ffmpeg_branding="Chrome"
	is_component_ffmpeg=true
	use_vaapi=true
	enable_widevine=true
	rtc_use_pipewire=true
	rtc_link_pipewire=true
	disable_fieldtrial_testing_config=true
	use_system_libwayland=false
	use_system_libffi=true
	use_qt=false
	enable_remoting=false
	rust_sysroot_absolute="/app/lib/sdk/rust-nightly"
	rustc_version="$(/app/lib/sdk/rust-nightly/bin/rustc -V)"
	rust_bindgen_root="$PWD/bindgen"
	chrome_pgo_phase=${chrome_pgo_phase}
EOF
tools/gn/bootstrap/bootstrap.py -v --no-clean --skip-generate-buildfiles -j"${FLATPAK_BUILDER_N_JOBS}"

mkdir -p out/ReleaseFree
cp out/Release{,Free}/args.gn
echo -e 'proprietary_codecs = false\nffmpeg_branding = "Chromium"' >> out/ReleaseFree/args.gn
out/Release/gn gen out/Release
out/Release/gn gen out/ReleaseFree
