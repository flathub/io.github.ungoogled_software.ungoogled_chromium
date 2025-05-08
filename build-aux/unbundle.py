#!/usr/bin/python3 -B

import sys

sys.path.append("build/linux/unbundle")

import replace_gn_files  # type: ignore

KEEPERS = (
    # Not present in SDK.
    "crc32c",
    "double-conversion",
    "flatbuffers",
    "highway",
    "jsoncpp",
    "libsecret",
    "libusb",
    "libXNVCtrl",
    "libyuv",
    "openh264",  # https://gitlab.com/freedesktop-sdk/freedesktop-sdk/-/commit/719900f1db1b5a5579bca419f70916cec7c05055
    "re2",
    "simdutf",
    "snappy",
    "swiftshader-SPIRV-Headers",
    "swiftshader-SPIRV-Tools",
    "vulkan_memory_allocator",
    "vulkan-SPIRV-Headers",
    "vulkan-SPIRV-Tools",
    "woff2",
    #
    # Present in SDK, but causes issues when unbundled.
    "absl_algorithm",  # all absl bundled due to https://crbug.com/339654390
    "absl_base",
    "absl_cleanup",
    "absl_container",
    "absl_crc",
    "absl_debugging",
    "absl_flags",
    "absl_functional",
    "absl_hash",
    "absl_log_internal",
    "absl_log",
    "absl_memory",
    "absl_meta",
    "absl_numeric",
    "absl_random",
    "absl_status",
    "absl_strings",
    "absl_synchronization",
    "absl_time",
    "absl_types",
    "absl_utility",
    "ffmpeg",  # https://crbug.com/40218408
    "fontconfig",  # https://github.com/ungoogled-software/ungoogled-chromium-flatpak/issues/29
    "freetype",  # https://github.com/ungoogled-software/ungoogled-chromium-flatpak/issues/29
    "libaom",  # https://crbug.com/aomedia/42302569
    "libvpx",  # https://crbug.com/1307941
    "zlib",  # https://crbug.com/40225256
)
TO_REMOVE = [lib for lib in replace_gn_files.REPLACEMENTS if lib not in KEEPERS]


def DoMain(_):
    # Ensure all libraries in KEEPERS are in replace_gn_files. This helps
    # keep the list in sync with Chromium.
    should_exit = False
    for lib in KEEPERS:
        if lib not in replace_gn_files.REPLACEMENTS:
            print(f"ERROR: {lib} is not in replace_gn_files", file=sys.stderr)
            should_exit = True
    if should_exit:
        sys.exit(1)

    # Replace bundled libraries with system libraries.
    replace_gn_files.DoMain(["--system-libraries", *TO_REMOVE])


if __name__ == "__main__":
    DoMain([])
