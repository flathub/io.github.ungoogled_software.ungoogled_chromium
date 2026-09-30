#!/bin/bash
set -euxo pipefail

out/Release/gn gen out/Release --fail-on-unused-args
python3 "${step_dir}/0055-check-build-inputs.py"
