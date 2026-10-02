#!/bin/bash
set -euxo pipefail

# Include the default GN args
mapfile -t flags < uc/flags.gn

# Always cache the pinned compilers, independent of flatpak-builder --ccache.
flags+=('cc_wrapper = "/app/bin/sccache"')

# Keep default VAAPI support on x86_64 and use V4L2 on aarch64
case "${FLATPAK_ARCH}" in
	x86_64)
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
flags+=('use_sysroot = false')

# Enabled features
flags+=('ffmpeg_branding = "Chrome"')
flags+=('is_official_build = true')
flags+=('link_pulseaudio = true')
flags+=('proprietary_codecs = true')
flags+=('rtc_use_pipewire = true')
flags+=('use_system_libffi = true')

mkdir -pv out/Release
printf "%s\n" "${flags[@]}" > out/Release/args.gn
