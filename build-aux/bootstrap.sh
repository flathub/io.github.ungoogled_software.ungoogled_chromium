#!/bin/bash -ex

# Needed to build GN itself.
. /usr/lib/sdk/llvm19/enable.sh

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

# Required so that rust-bindgen can find libclang
# https://rust-lang.github.io/rust-bindgen/requirements.html
# https://source.chromium.org/chromium/chromium/src/+/main:build/rust/rust_bindgen.gni;l=20-27;drc=09afac1d1aa18250073002ddedd0e064e4c2a981
cp -r /app/lib/sdk/bindgen bindgen
ln -s /usr/lib/sdk/llvm19/lib -t bindgen

# Create initial args.gn from Ungoogled Chromium's flags.gn
mkdir -p out/Release
cp ./uc/src/flags.gn out/Release/args.gn

# Use system Rust and Clang
cat >> out/Release/args.gn <<-EOF
	rust_sysroot_absolute="/usr/lib/sdk/rust-stable"
	rust_bindgen_root="${PWD}/bindgen"
	rustc_version="$(/usr/lib/sdk/rust-stable/bin/rustc -V)"
	clang_base_path="/usr/lib/sdk/llvm19"
	clang_version="$(clang --version | grep -m1 version | sed 's/.* \([0-9]\+\).*/\1/')"
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

# Use ThinLTO for faster builds
cat >> out/Release/args.gn <<-EOF
	use_thin_lto=true
EOF

# Disabled features
cat >> out/Release/args.gn <<-EOF
	is_debug=false
	use_sysroot=false
	safe_browsing_use_unrar=false
	enable_vr=false
	build_dawn_tests=false
	enable_iterator_debugging=false
	angle_has_histograms=false
	angle_build_tests=false
	build_angle_perftests=false
	treat_warnings_as_errors=false
	use_qt=false
	is_cfi=false
	icu_use_data_file=false
EOF

# Enabled features
cat >> out/Release/args.gn <<-EOF
	use_gio=true
	is_official_build=true
	symbol_level=0
	use_pulseaudio=true
	link_pulseaudio=true
	rtc_use_pipewire=true
	v8_enable_backtrace=true
	use_system_lcms2=true
	use_system_libjpeg=true
	use_system_libopenjpeg2=true
	use_system_libpng=true
	use_system_libtiff=false
	use_system_freetype=true
	use_system_harfbuzz=true
	use_system_libffi=true
	use_system_libwayland=true
	proprietary_codecs=true
	ffmpeg_branding="Chrome"
	chrome_pgo_phase=2
EOF

# Bootstrap GN
tools/gn/bootstrap/bootstrap.py -v --no-clean --skip-generate-buildfiles -j"${FLATPAK_BUILDER_N_JOBS}"
