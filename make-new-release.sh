#!/usr/bin/env bash
set -euxo pipefail

die() {
	echo >&2 "$@"
	exit 1
}

# shellcheck disable=SC2034
SED_BINARIES=(gsed sed)

if [[ $# -ne 1 ]]; then
	die "Usage: $0 <version>"
fi

VERSION="$1"
DATE=$(date -u -I)
METAFILE="io.github.ungoogled_software.ungoogled_chromium.metainfo.xml"
COMMIT_MSG="Update Ungoogled Chromium to ${VERSION}"

choose_and_run() {
	local -n binaries="$1"
	shift

	local binary
	for binary in "${binaries[@]}"; do
		if command -v "${binary}" &> /dev/null; then
			"${binary}" "$@"
			return
		fi
	done

	die "No suitable binary found for: ${binaries[*]}"
}

choose_and_run SED_BINARIES -i "/<releases>/a \\
    <release version=\"${VERSION}\" date=\"${DATE}\" />" "${METAFILE}"
git add "${METAFILE}"
git commit -sm "${COMMIT_MSG}"
