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
cp -r /app/lib/sdk/bindgen bindgen
ln -s /usr/lib/sdk/llvm19/lib -t bindgen

# (TODO: enable use_qt in the future?)
mkdir -p out/Release
cp ./uc/src/flags.gn out/Release/args.gn
cat >> out/Release/args.gn <<-EOF
	custom_toolchain="//build/toolchain/linux/unbundle:default"
	host_toolchain="//build/toolchain/linux/unbundle:default"
	use_sysroot=false
	use_lld=true
	enable_nacl=false
	blink_symbol_level=0
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
	clang_base_path="/usr/lib/sdk/llvm19"
	clang_use_chrome_plugins=false
	clang_version="$(clang --version | grep -m1 version | sed 's/.* \([0-9]\+\).*/\1/')"
	chrome_pgo_phase=2
	rust_sysroot_absolute="/usr/lib/sdk/rust-stable"
	rust_bindgen_root="${PWD}/bindgen"
	rustc_version="$(/usr/lib/sdk/rust-stable/bin/rustc -V)"
EOF
tools/gn/bootstrap/bootstrap.py -v --no-clean --skip-generate-buildfiles -j"${FLATPAK_BUILDER_N_JOBS}"
