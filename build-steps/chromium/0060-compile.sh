#!/bin/bash
set -euxo pipefail

ninja -C out/Release -j"${FLATPAK_BUILDER_N_JOBS}" chrome chrome_crashpad_handler

/app/bin/sccache --show-stats
