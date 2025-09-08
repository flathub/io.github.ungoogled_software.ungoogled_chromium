#!/bin/bash
set -euxo pipefail

ln_overwrite_all() {
	rm -rfv "$2"
	ln -svf "$1" "$2"
}

# Set custom flags and disable SDK defaults
# https://gitlab.com/freedesktop-sdk/freedesktop-sdk/-/blob/release/24.08/include/flags.yml
export CFLAGS='' CXXFLAGS='' CPPFLAGS=''
unset LDFLAGS RUSTFLAGS

# Facilitate deterministic builds (taken from build/config/compiler/BUILD.gn)
CFLAGS+='   -Wno-builtin-macro-redefined'
CXXFLAGS+=' -Wno-builtin-macro-redefined'
CPPFLAGS+=' -D__DATE__=  -D__TIME__=  -D__TIMESTAMP__='

# Do not warn about unknown warning options
CFLAGS+='   -Wno-unknown-warning-option'
CXXFLAGS+=' -Wno-unknown-warning-option'

# Apply Ungoogled Chromium changes
uc/utils/prune_binaries.py . uc/pruning.list
uc/utils/patches.py apply . uc/patches
uc/utils/domain_substitution.py apply -r uc/domain_regex.list \
	-f uc/domain_substitution.list -c domsubcache.tar.gz .

# Link our verisons of Node and OpenJDK into Chromium so the build scripts will
# use them. For OpenJDK especially, this is a workaround for:
# https://bugs.chromium.org/p/chromium/issues/detail?id=1192875
ln_overwrite_all "${NODE_HOME}" third_party/node/linux/node-linux-x64
ln_overwrite_all "${JAVA_HOME}" third_party/jdk/current

# Run our unbundling script in order to use system libraries where possible
./unbundle.py

# Allow building against system libraries in official builds
sed -i 's/OFFICIAL_BUILD/GOOGLE_CHROME_BUILD/' \
	tools/generate_shim_headers/generate_shim_headers.py

# https://crbug.com/893950
sed -i -e 's/\<xmlMalloc\>/malloc/' -e 's/\<xmlFree\>/free/' \
	-e '1i #include <cstdlib>' \
	third_party/blink/renderer/core/xml/*.cc \
	third_party/blink/renderer/core/xml/parser/xml_document_parser.cc \
	third_party/libxml/chromium/*.cc

# Include the default GN args
mapfile -t flags < uc/flags.gn

# Define a custom toolchain
flags+=('custom_toolchain = "//build/toolchain/linux/unbundle:default"')

# Required so that rust-bindgen can find libclang
# https://rust-lang.github.io/rust-bindgen/requirements.html
# https://source.chromium.org/chromium/chromium/src/+/main:build/rust/rust_bindgen.gni;l=20-27;drc=09afac1d1aa18250073002ddedd0e064e4c2a981
mkdir -pv bindgen/bin
bindgen_path=$(command -v bindgen)
if [[ -z "${bindgen_path}" ]]; then
	echo 'Error: bindgen not found in PATH' >&2
	exit 1
fi
ln -svf "${bindgen_path}" bindgen/bin/bindgen
ln -svf "${LIBCLANG_PATH}" -t bindgen

# Determine the Rust toolchain version and sysroot
RUST_SYSROOT_ABSOLUTE=$(rustc --print sysroot)
RUSTC_VERSION=$(rustc -V)
export RUST_SYSROOT_ABSOLUTE RUSTC_VERSION

# Configure the Rust toolchain
flags+=(
	'rust_sysroot_absolute = getenv("RUST_SYSROOT_ABSOLUTE")'
	'rust_bindgen_root = getenv("PWD") + "/bindgen"'
	'rustc_version = getenv("RUSTC_VERSION")'
)

# Determine the Clang toolchain version and base path
CLANG_BASE_PATH=$(llvm-config --prefix)
CLANG_VERSION=$(llvm-config --version | awk -F. '{print $1}')
export CLANG_BASE_PATH CLANG_VERSION

# Configure the Clang toolchain
flags+=(
	'clang_base_path = getenv("CLANG_BASE_PATH")'
	'clang_version = getenv("CLANG_VERSION")'
	'host_toolchain = "//build/toolchain/linux/unbundle:default"'
)

# Use ccache if enabled by flatpak-builder
if [[ "${CCACHE_DIR}" == "/run/ccache" ]]; then
	flags+=('cc_wrapper = "ccache"')
fi

# Use VAAPI on x86_64 and V4L2 on aarch64
case "${FLATPAK_ARCH}" in
	x86_64)
		flags+=('use_vaapi = true')
		;;
	aarch64)
		flags+=(
			'use_v4l2_codec = true'
			'use_vaapi = false'
		)
		;;
	*)
		echo >&2 "Unsupported architecture: ${FLATPAK_ARCH}"
		exit 1
		;;
esac

# The SDK provides libtiff 4.6.0, but TIFFOpenOptionsSetMaxCumulatedMemAlloc()
# is available only from libtiff 4.7 onwards. Therefore, we disable the SDK's
# libtiff and use the bundled version instead.
flags+=('use_system_libtiff = false')

# Disabled features
flags+=('symbol_level = 0')
flags+=('use_qt5 = false')
flags+=('use_qt6 = false')
flags+=('use_sysroot = false')

# Enabled features
flags+=('ffmpeg_branding = "Chrome"')
flags+=('is_official_build = true')
flags+=('link_pulseaudio = true')
flags+=('proprietary_codecs = true')
flags+=('rtc_use_pipewire = true')
flags+=('use_pulseaudio = true')
flags+=('use_system_freetype = true')
flags+=('use_system_harfbuzz = true')
flags+=('use_system_lcms2 = true')
flags+=('use_system_libjpeg = true')
flags+=('use_system_libopenjpeg2 = true')
flags+=('use_system_libpng = true')
flags+=('use_system_libwayland = true')
flags+=('use_system_minigbm = true')

# Bootstrap GN
tools/gn/bootstrap/bootstrap.py -v --no-clean --skip-generate-buildfiles -j"${FLATPAK_BUILDER_N_JOBS}"

# Configure and build Chromium
out/Release/gn gen --args="${flags[*]}" out/Release --fail-on-unused-args
ninja -C out/Release -j"${FLATPAK_BUILDER_N_JOBS}" chrome chrome_crashpad_handler
