#!/bin/bash
set -euxo pipefail

# Flatpak runs this from the Chromium source root. Source shell stages so
# compiler paths and environment set in 0020-setup-build-tools.sh remain available to later stages.
step_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${step_dir}/0010-prepare-source.sh"
source "${step_dir}/0020-setup-build-tools.sh"
source "${step_dir}/0030-write-gn-args.sh"
source "${step_dir}/0040-bootstrap-gn.sh"
source "${step_dir}/0050-generate-build-files.sh"
source "${step_dir}/0060-compile.sh"
