#!/bin/bash -ex

# Chromium's Rust output paths and sysroots need adaptation for sccache.
export RUSTC_WRAPPER="$PWD/rustc-cache.py"
ninja -C out/Release -j"$FLATPAK_BUILDER_N_JOBS" chrome chrome_crashpad_handler
/app/bin/sccache --show-stats
