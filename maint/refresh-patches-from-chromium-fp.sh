#!/usr/bin/env bash

set -eu

BRANCH=${1-master}
IGNORE_FILES=(
	"patches/chromium/Revert-cppgc-Decommit-pooled-pages-by-default.patch"
	"patches/chromium/increase-fortify-level.patch"
)

git fetch https://github.com/flathub/org.chromium.chromium.git "${BRANCH}"

all_patches=(patches/*/*.patch)
files_to_checkout=()

for file in "${all_patches[@]}"; do
	skip=0
	for ignore in "${IGNORE_FILES[@]}"; do
		if [[ "$file" == "$ignore" ]]; then
			skip=1
			break
		fi
	done

	[ $skip -eq 0 ] && files_to_checkout+=("$file")
done

if [ ${#files_to_checkout[@]} -gt 0 ]; then
	git checkout FETCH_HEAD "${files_to_checkout[@]}"
else
	echo >&2 "No patch files to checkout."
	exit 1
fi
