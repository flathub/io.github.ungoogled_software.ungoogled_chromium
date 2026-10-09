#!/bin/bash
set -euxo pipefail

# Bootstrap GN
CC="/app/bin/sccache ${CC}" CXX="/app/bin/sccache ${CXX}" \
	tools/gn/bootstrap/bootstrap.py -v --no-clean --skip-generate-buildfiles -j"${FLATPAK_BUILDER_N_JOBS}"

# V8's metagen looks for GN here on both x86_64 and aarch64.
mkdir -p buildtools/linux64
ln -sf "${PWD}/out/Release/gn" buildtools/linux64/gn
