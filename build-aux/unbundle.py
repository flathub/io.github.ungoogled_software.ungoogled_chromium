#!/usr/bin/python3 -B

import sys

sys.path.append("build/linux/unbundle")

import replace_gn_files  # type: ignore

# https://chromium.googlesource.com/chromium/src/+/refs/heads/main/build/linux/unbundle/replace_gn_files.py
TO_REMOVE = [
    "fontconfig",
    "freetype",
]


def DoMain(_):
    # Ensure all libraries in TO_REMOVE are in replace_gn_files. This helps
    # keep the list in sync with Chromium.
    should_exit = False
    for lib in TO_REMOVE:
        if lib not in replace_gn_files.REPLACEMENTS:
            print(f"ERROR: {lib} is not in replace_gn_files", file=sys.stderr)
            should_exit = True
    if should_exit:
        sys.exit(1)

    # Replace bundled libraries with system libraries.
    replace_gn_files.DoMain(["--system-libraries", *TO_REMOVE])


if __name__ == "__main__":
    DoMain([])
