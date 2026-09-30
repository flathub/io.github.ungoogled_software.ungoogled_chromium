#!/bin/bash
set -euxo pipefail

# The bootstrap is the beta pinned in Rust's src/stage0, not SDK Rust.
for component in rustc cargo rust-std; do
    "bootstrap-${component}/install.sh" --prefix="${PWD}/bootstrap" --disable-ldconfig
done
