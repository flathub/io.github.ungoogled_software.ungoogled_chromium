#!/bin/sh

# Fail on error
set -e

# Fail on unset variables
set -u

# Set IFS to only split by newline
IFS='
'

# Helper function to print to stderr
echoerr() {
    printf "%s\n" "${*}" >&2
}

# Check for required tools
DEPS="
jq
git
curl
base64
sha256sum
grep
awk
cut"
for dep in ${DEPS:?}; do
    if ! command -v "${dep:?}" >/dev/null; then
        echoerr "Error: ${dep:?} is not installed"
        exit 1
    fi
done

# Make sure we're using GNU grep
if ! grep --version 2>/dev/null | grep -q 'GNU grep'; then
    echoerr "Error: GNU grep is required"
    exit 1
fi

# UC version is {chromium_version}-{uc_revision}-{fp_revision}
uc_version=${1:?}
chromium_version=${uc_version%-*} # Remove the FP revision
chromium_version=${chromium_version%-*} # Remove the Ungoogled Chromium revision
echoerr "Ungoogled Chromium version: ${uc_version:?}"
echoerr "Chromium version: ${chromium_version:?}"

# Create a new branch from the latest master
git fetch origin master
git checkout -b "update-uc-${uc_version:?}" origin/master

# Get the Chromium SHA256 hash
#chromium_url="https://chromium-tarballs.distfiles.gentoo.org/chromium-${chromium_version}-linux.tar.xz"
chromium_url="https://commondatastorage.googleapis.com/chromium-browser-official/chromium-${chromium_version}.tar.xz"
chromium_sha256=$(curl -L -s -f "${chromium_url:?}.hashes" | awk '/^sha256\s+/ {print $2}')
echoerr "Chromium URL: ${chromium_url:?}"
echoerr "Chromium SHA256: ${chromium_sha256:?}"

# Get the Ungoogled Chromium tag and commit
uc_url=$(jq -r '.[0].url' sources/ungoogled-chromium.json)
uc_tag=${uc_version:?}
uc_commit=$(git ls-remote --tags "${uc_url:?}" "refs/tags/${uc_tag:?}" | cut -f1)
echoerr "Ungoogled Chromium tag: ${uc_tag:?}"
echoerr "Ungoogled Chromium commit: ${uc_commit:?}"

# Update the Chromium version
jq --arg chromium_url "${chromium_url}" \
   --arg chromium_sha256 "${chromium_sha256}" \
   '.[0] |= (.url = $chromium_url | .sha256 = $chromium_sha256)' sources/chromium.json > sources/chromium.json.tmp
mv sources/chromium.json.tmp sources/chromium.json

# Update the Ungoogled Chromium version
jq --arg uc_tag "${uc_tag}" \
   --arg uc_commit "${uc_commit}" \
   '.[0] |= (.tag = $uc_tag | .commit = $uc_commit)' sources/ungoogled-chromium.json > sources/ungoogled-chromium.json.tmp
mv sources/ungoogled-chromium.json.tmp sources/ungoogled-chromium.json

# Stash the changes
git stash push -m "Update Ungoogled Chromium to ${uc_version:?}"

# Fetch org.chromium.Chromium and offer to cherry-pick commits
git remote add org.chromium.Chromium https://github.com/flathub/org.chromium.chromium 2>/dev/null || true
git fetch org.chromium.Chromium master
last_checked_commit=$(cat maint/.org.chromium.Chromium.last_checked_commit)
commits_to_consider=$(git log --pretty='%ae %h %s' --no-merges --reverse \
    "${last_checked_commit:?}..org.chromium.Chromium/master" | \
    grep -v '^sysadmin@flathub.org ' || true
)
for commit in ${commits_to_consider}; do
    commit_hash=$(printf '%s\n' "${commit}" | awk '{print $2}')
    commit_subject=$(printf '%s\n' "${commit}" | cut -d' ' -f3-)
    while true; do
        printf "Apply commit %s: %s? [y/N] " "${commit_hash}" "${commit_subject}" >&2
        read -r REPLY || true
        if [ "${REPLY}" = "y" ] || [ "${REPLY}" = "Y" ]; then
            git cherry-pick -xs "${commit_hash:?}" || true
            echoerr "Dropped to shell. Press Ctrl+D to continue cherry-picking."
            "${SHELL:-/bin/sh}" || true
            break
        elif [ "${REPLY}" = "n" ] || [ "${REPLY}" = "N" ] || [ -z "${REPLY}" ]; then
            break
        fi
    done
    printf '%s\n' "${commit_hash:?}" > maint/.org.chromium.Chromium.last_checked_commit
done

# Pop the stashed changes
git stash pop || true

# Add files to index
git add \
    sources/chromium.json \
    sources/ungoogled-chromium.json \
    maint/.org.chromium.Chromium.last_checked_commit

# Create a new commit and push the changes
git commit -s -m "Update Ungoogled Chromium to ${uc_version:?}" || true
git push -u origin "update-uc-${uc_version:?}"

# Exit with success
exit 0
