#!/bin/bash
set -euxo pipefail

# Include the default GN args
mapfile -t flags < uc/flags.gn

# Native ARM Rust does not include the Bazel-built Crubit generators yet.
if [[ "${FLATPAK_ARCH}" == "aarch64" ]]; then
	export RUST_SYSROOT_ABSOLUTE=/app/toolchains/rust
	export RUSTC_VERSION
	# Custom sysroots pass this straight through as rustc_revision. Match
	# build/config/rust.gni's normalization of Google's VERSION stamp so the
	# compiler consistency check still validates the pinned Rust subrevision.
	RUSTC_VERSION=$(cat third_party/rust-toolchain/VERSION)
	RUSTC_VERSION=${RUSTC_VERSION//rustc /}
	RUSTC_VERSION=${RUSTC_VERSION// chromium/}
	RUSTC_VERSION=${RUSTC_VERSION//init-/}
	RUSTC_VERSION=${RUSTC_VERSION//llvmorg-/}
	RUSTC_VERSION=${RUSTC_VERSION// /}
	RUSTC_VERSION=${RUSTC_VERSION//./}
	RUSTC_VERSION=${RUSTC_VERSION//\(/-}
	RUSTC_VERSION=${RUSTC_VERSION//\)/}
	flags+=(
		'rust_sysroot_absolute = getenv("RUST_SYSROOT_ABSOLUTE")'
		'rustc_version = getenv("RUSTC_VERSION")'
	)
fi

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
			'use_av1_hw_decoder = true'
		)
		;;
	*)
		echo >&2 "Unsupported architecture: ${FLATPAK_ARCH}"
		exit 1
		;;
esac

# Disabled features
flags+=('symbol_level = 0')
flags+=('use_qt5 = false')
flags+=('use_qt6 = false')
flags+=('use_sysroot = false')
flags+=('use_clang_modules = false')

# Enabled features
flags+=('ffmpeg_branding = "Chrome"')
flags+=('is_official_build = true')
flags+=('link_pulseaudio = true')
flags+=('proprietary_codecs = true')
flags+=('rtc_use_pipewire = true')
flags+=('use_pulseaudio = true')
flags+=('use_system_libffi = true')

mkdir -pv out/Release
printf "%s\n" "${flags[@]}" > out/Release/args.gn
