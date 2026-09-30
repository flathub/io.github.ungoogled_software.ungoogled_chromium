#!/bin/bash
set -euxo pipefail

# Bootstrap GN
tools/gn/bootstrap/bootstrap.py -v --no-clean --skip-generate-buildfiles -j"${FLATPAK_BUILDER_N_JOBS}"
