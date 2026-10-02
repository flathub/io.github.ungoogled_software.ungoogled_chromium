#!/bin/bash
set -euxo pipefail

# Bootstrap GN
CC="/app/bin/sccache ${CC}" CXX="/app/bin/sccache ${CXX}" \
	tools/gn/bootstrap/bootstrap.py -v --no-clean --skip-generate-buildfiles -j"${FLATPAK_BUILDER_N_JOBS}"
