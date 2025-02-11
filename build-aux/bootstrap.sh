#!/bin/bash -ex

# Possible replacements are listed in build/linux/unbundle/replace_gn_files.py
SYSTEM_LIBS=(
	brotli
	#dav1d
	#ffmpeg		# YouTube playback stopped working in Chromium 120
	flac
	fontconfig
	freetype
	harfbuzz-ng
	icu
	#jsoncpp	# needs libstdc++
	#libaom
	#libavif	# needs -DAVIF_ENABLE_EXPERIMENTAL_GAIN_MAP=ON
	libjpeg
	libpng
	#libvpx
	libwebp
	libxml
	libxslt
	opus
	#re2		# needs libstdc++
	#snapp		# needs libstdc++
	#woff2		# needs libstdc++
	#zlib
)
UNWANTED_BUNDLED_LIBS=(
	$(printf "%s\n" ${SYSTEM_LIBS[@]} | sed 's/^libjpeg$/&_turbo/')
)

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

# Remove bundled libraries for which we will use the system copies; this
# *should* do what the remove_bundled_libraries.py script does, with the
# added benefit of not having to list all the remaining libraries
for lib in ${UNWANTED_BUNDLED_LIBS[@]}; do
	find "third_party/${lib}" -type f \
		\! -path "third_party/${lib}/chromium/*" \
		\! -path "third_party/${lib}/google/*" \
		\! -path "third_party/harfbuzz-ng/utils/hb_scoped.h" \
		\! -regex '.*\.\(gn\|gni\|isolate\)' \
		-delete
done

./build/linux/unbundle/replace_gn_files.py \
	--system-libraries "${SYSTEM_LIBS[@]}"

# Create flags for the Release build.
# (TODO: enable use_qt in the future?)
mkdir -p out/Release
cp ./uc/src/flags.gn out/Release/args.gn
cat >> out/Release/args.gn <<-EOF
	custom_toolchain="//build/toolchain/linux/unbundle:default"
	host_toolchain="//build/toolchain/linux/unbundle:default"
	is_official_build=true
	symbol_level=0
	blink_enable_generated_code_formatting=false
	ffmpeg_branding="Chrome"
	proprietary_codecs=true
	is_component_ffmpeg=true
	rtc_use_pipewire=true
	link_pulseaudio=true
	use_sysroot=false
	use_system_libffi=true
	use_qt=false
	use_vaapi=true
	enable_platform_hevc=true
	enable_hevc_parser_and_hw_decoder=true
	icu_use_data_file=false
	clang_base_path="/usr/lib/sdk/llvm19"
	clang_version="$(clang --version | grep -m1 version | sed 's/.* \([0-9]\+\).*/\1/')"
	rust_sysroot_absolute="/usr/lib/sdk/rust-stable"
	rust_bindgen_root="${PWD}/bindgen"
	rustc_version="$(/usr/lib/sdk/rust-stable/bin/rustc -V)"
EOF
tools/gn/bootstrap/bootstrap.py -v --no-clean --skip-generate-buildfiles -j"${FLATPAK_BUILDER_N_JOBS}"

# Create flags for the ReleaseFree build.
mkdir -p out/ReleaseFree
cp out/Release{,Free}/args.gn
cat >> out/ReleaseFree/args.gn <<-EOF
	proprietary_codecs=false
	ffmpeg_branding="Chromium"
	enable_platform_hevc=false
	enable_hevc_parser_and_hw_decoder=false
EOF
