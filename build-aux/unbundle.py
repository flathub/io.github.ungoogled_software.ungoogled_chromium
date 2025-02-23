#!/usr/bin/python3 -B

import sys

sys.path.append("build/linux/unbundle")

import replace_gn_files  # type: ignore

keepers = (
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
    "libaom",  # media/gpu/vaapi/BUILD.gn depends on libaomrc, no upstream bug yet
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
to_remove = set()

for lib in keepers:
    if lib not in replace_gn_files.REPLACEMENTS:
        print(f"ERROR: {lib} is invalid. Please update keepers list.", file=sys.stderr)
        sys.exit(1)

for lib, rule in replace_gn_files.REPLACEMENTS.items():
    if lib not in keepers:
        to_remove.add(lib)

replace_gn_files.DoMain(("--system-libraries", *to_remove))
