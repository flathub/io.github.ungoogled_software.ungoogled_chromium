#!/bin/bash
set -exo pipefail

# Needed to build GN itself.
. /usr/lib/sdk/llvm20/enable.sh

# GN will use these variables to configure its own build, but they introduce
# compat issues w/ Clang and aren't used by Chromium itself anyway, so just
# unset them here.
unset CFLAGS CXXFLAGS LDFLAGS

# Allow building against system libraries in official builds
sed -i 's/OFFICIAL_BUILD/GOOGLE_CHROME_BUILD/' \
	tools/generate_shim_headers/generate_shim_headers.py

# https://crbug.com/893950
sed -i -e 's/\<xmlMalloc\>/malloc/' -e 's/\<xmlFree\>/free/' \
	-e '1i #include <cstdlib>' \
	third_party/blink/renderer/core/xml/*.cc \
	third_party/blink/renderer/core/xml/parser/xml_document_parser.cc \
	third_party/libxml/chromium/*.cc

# Remove node version check dependency
# https://chromium-review.googlesource.com/c/chromium/src/+/6334038
sed -i '\#deps += \[ "//third_party/node:check_version" \]#d' \
	third_party/node/node.gni

# Required so that rust-bindgen can find libclang
# https://rust-lang.github.io/rust-bindgen/requirements.html
# https://source.chromium.org/chromium/chromium/src/+/main:build/rust/rust_bindgen.gni;l=20-27;drc=09afac1d1aa18250073002ddedd0e064e4c2a981
cp -r /app/lib/sdk/bindgen bindgen
ln -s /usr/lib/sdk/llvm20/lib -t bindgen

# Create initial args.gn from Ungoogled Chromium's flags.gn
mkdir -p out/Release
cp ./uc/flags.gn out/Release/args.gn

# Use system Rust and Clang
rustc_version=$(/usr/lib/sdk/rust-stable/bin/rustc -V)
clang_version=$(clang --version | grep -m1 version | sed 's/.* \([0-9]\+\).*/\1/')
cat >> out/Release/args.gn <<-EOF
	rust_sysroot_absolute="/usr/lib/sdk/rust-stable"
	rust_bindgen_root="${PWD}/bindgen"
	rustc_version="${rustc_version}"
	clang_base_path="/usr/lib/sdk/llvm20"
	clang_version="${clang_version}"
	custom_toolchain="//build/toolchain/linux/unbundle:default"
	host_toolchain="//build/toolchain/linux/unbundle:default"
EOF

# Use VAAPI on x86_64 and V4L2 on aarch64
case "${FLATPAK_ARCH}" in
	x86_64)
		cat >> out/Release/args.gn <<-EOF
			use_vaapi=true
		EOF
		;;
	aarch64)
		cat >> out/Release/args.gn <<-EOF
			use_v4l2_codec=true
			use_vaapi=false
		EOF
		;;
	*)
		echo >&2 "Unsupported architecture: ${FLATPAK_ARCH}"
		exit 1
		;;
esac

# Disabled features
cat >> out/Release/args.gn <<-EOF
	angle_build_tests=false
	angle_has_histograms=false
	blink_enable_generated_code_formatting=false
	build_angle_perftests=false
	build_dawn_tests=false
	devtools_skip_typecheck=false
	enable_iterator_debugging=false
	enable_nocompile_tests=false
	enable_perfetto_unittests=false
	enable_precompiled_headers=false
	enable_pseudolocales=false
	enable_screen_ai_browsertests=false
	enable_update_notifications=false
	enable_updater=false
	enable_vr=false
	icu_use_data_file=false
	is_debug=false
	rtc_build_examples=false
	skia_enable_skshaper_tests=false
	symbol_level=0
	tint_build_unittests=false
	use_qt5=false
	use_qt6=false
	use_sysroot=false
	use_system_libtiff=false
EOF

# Enabled features
cat >> out/Release/args.gn <<-EOF
	cc_wrapper="ccache"
	ffmpeg_branding="Chrome"
	is_official_build=true
	link_pulseaudio=true
	proprietary_codecs=true
	rtc_use_pipewire=true
	use_pulseaudio=true
	use_system_freetype=true
	use_system_harfbuzz=true
	use_system_lcms2=true
	use_system_libjpeg=true
	use_system_libopenjpeg2=true
	use_system_libpng=true
	use_system_libwayland=true
	use_system_minigbm=true
EOF

# Bootstrap GN
tools/gn/bootstrap/bootstrap.py -v --no-clean --skip-generate-buildfiles -j"${FLATPAK_BUILDER_N_JOBS}"
