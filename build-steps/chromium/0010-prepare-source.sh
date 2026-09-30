#!/bin/bash
set -euxo pipefail

# Apply Ungoogled Chromium changes
uc/utils/prune_binaries.py . uc/pruning.list
uc/utils/patches.py apply . uc/patches
uc/utils/domain_substitution.py apply -r uc/domain_regex.list \
	-f uc/domain_substitution.list -c domsubcache.tar.gz .
