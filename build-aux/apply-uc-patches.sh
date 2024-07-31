#!/bin/bash -ex

# Apply Flatpak specific branding
./uc/branding/infect.sh ./uc ./

# Prune binaries but keep Google toolchain binaries
./uc/src/utils/prune_binaries.py --keep-contingent-paths ./ ./uc/src/pruning.list

# Apply patches
./uc/src/utils/patches.py apply ./ ./uc/src/patches

# Substitute domains
./uc/src/utils/domain_substitution.py apply -r ./uc/src/domain_regex.list \
    -f ./uc/src/domain_substitution.list -c ./domsubcache.tar.gz ./
