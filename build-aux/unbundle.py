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
    "re2",
    "snappy",
    "swiftshader-SPIRV-Headers",
    "swiftshader-SPIRV-Tools",
    "vulkan-SPIRV-Headers",
    "vulkan-SPIRV-Tools",
    "vulkan_memory_allocator",
    "woff2",
    # Present in SDK, but causes issues when unbundled.
    "libvpx",  # https://crbug.com/1307941
    "libaom",  # https://crbug.com/aomedia/42302569
    "absl_algorithm",  # all absl bundled due to https://crbug.com/339654390
    "absl_base",
    "absl_cleanup",
    "absl_container",
    "absl_crc",
    "absl_debugging",
    "absl_flags",
    "absl_functional",
    "absl_hash",
    "absl_log",
    "absl_log_internal",
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
    "zlib",  # 'undefined symbol: Cr_z_crc32_z' when linking with system zlib
    "ffmpeg",  # https://crbug.com/40218408
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
