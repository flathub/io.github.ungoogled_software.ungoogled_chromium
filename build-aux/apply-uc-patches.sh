#!/bin/bash
set -exo pipefail

# Apply Flatpak specific branding
cp -rv ./branding/to_copy/. .

# Prune binaries
./uc/utils/prune_binaries.py ./ ./uc/pruning.list

# Apply patches
./uc/utils/patches.py apply ./ ./uc/patches

# Substitute domains
./uc/utils/domain_substitution.py apply -r ./uc/domain_regex.list \
	-f ./uc/domain_substitution.list -c ./domsubcache.tar.gz ./
