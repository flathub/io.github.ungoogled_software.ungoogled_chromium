#!/bin/sh

# Fail on error
set -e

# Fail on unset variables
set -u

# Helper function to print to stderr
echoerr() {
    printf "%s\n" "${*}" >&2
}

# Check for required tools
DEPS="jq git curl base64 sha256sum grep awk cut"
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

# UGC version is {chromium_version}-{ugc_revision}
ugc_version=${1:?}
chromium_version=${ugc_version%-*}
echoerr "UGC version: ${ugc_version:?}"
echoerr "Chromium version: ${chromium_version:?}"

# Create a new branch from the latest master
git fetch origin master
git checkout -b "update-ugc-${ugc_version:?}" origin/master

# Extract the LLVM version from the update.py script
clang_update_script=$(curl -L -s -f "https://chromium.googlesource.com/chromium/src/+/${chromium_version}/tools/clang/scripts/update.py?format=TEXT" | base64 -d)
clang_version=$(printf %s "${clang_update_script:?}" | grep -oP "CLANG_REVISION = '(.*?)'" | cut -d"'" -f2) # llvmorg-19-init-9433-g76ea5feb
clang_subversion=$(printf %s "${clang_update_script:?}" | grep -oP "CLANG_SUB_REVISION = (\d+)" | cut -d' ' -f3) # 1
echoerr "Clang version: ${clang_version:?}"
echoerr "Clang subversion: ${clang_subversion:?}"

# Extract the SHA256 hash of the Clang x64 tarball
clang_tarball_url="https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64/clang-${clang_version}-${clang_subversion}.tar.xz"
clang_sha256=$(curl -L -s -f "${clang_tarball_url:?}" | sha256sum | cut -d' ' -f1)
echoerr "Clang tarball URL: ${clang_tarball_url:?}"
echoerr "Clang tarball SHA256: ${clang_sha256:?}"

# Get the Chromium SHA256 hash
chromium_url="https://commondatastorage.googleapis.com/chromium-browser-official/chromium-${chromium_version}.tar.xz"
chromium_sha256=$(curl -L -s -f "${chromium_url:?}.hashes" | grep -iE '^sha256\s+' | awk '{print $2}')
echoerr "Chromium URL: ${chromium_url:?}"
echoerr "Chromium SHA256: ${chromium_sha256:?}"

# Get the UGC tag and commit
ugc_url=$(jq -r '.[0].url' sources/ugc.json)
ugc_tag=${ugc_version:?}
ugc_commit=$(git ls-remote --tags "${ugc_url:?}" "refs/tags/${ugc_tag:?}" | cut -f1)
echoerr "UGC tag: ${ugc_tag:?}"
echoerr "UGC commit: ${ugc_commit:?}"

# Get the Rust Nightly version
rust_nightly_version=$(curl -L -s -f "https://static.rust-lang.org/dist/channel-rust-nightly.toml" | grep -oP 'date = "(.*?)"' | cut -d'"' -f2)
echoerr "Rust Nightly version: ${rust_nightly_version:?}"
url_aarch64="https://static.rust-lang.org/dist/${rust_nightly_version:?}/rust-nightly-aarch64-unknown-linux-gnu.tar.xz"
sha256_aarch64=$(curl -L -s -f "${url_aarch64:?}.sha256" | cut -d' ' -f1)
url_x86_64="https://static.rust-lang.org/dist/${rust_nightly_version:?}/rust-nightly-x86_64-unknown-linux-gnu.tar.xz"
sha256_x86_64=$(curl -L -s -f "${url_x86_64:?}.sha256" | cut -d' ' -f1)
url_src="https://static.rust-lang.org/dist/${rust_nightly_version:?}/rust-src-nightly.tar.xz"
sha256_src=$(curl -L -s -f "${url_src:?}.sha256" | cut -d' ' -f1)

# Update the Chromium version
jq --arg clang_version "${clang_version}" \
   --arg clang_tarball_url "${clang_tarball_url}" \
   --arg clang_sha256 "${clang_sha256}" \
   --arg chromium_url "${chromium_url}" \
   --arg chromium_sha256 "${chromium_sha256}" \
   '.[0] |= (.url = $chromium_url | .sha256 = $chromium_sha256) |
    .[1] |= (.url = $clang_tarball_url | .sha256 = $clang_sha256) |
    .[3] |= (.commit = $clang_version)' sources/chromium.json > sources/chromium.json.tmp
mv sources/chromium.json.tmp sources/chromium.json

# Update the UGC version
jq --arg ugc_tag "${ugc_tag}" \
   --arg ugc_commit "${ugc_commit}" \
   '.[0] |= (.tag = $ugc_tag | .commit = $ugc_commit)' sources/ugc.json > sources/ugc.json.tmp
mv sources/ugc.json.tmp sources/ugc.json

# Update the Rust Nightly version
jq --arg rust_nightly_version "${rust_nightly_version}" \
   --arg url_aarch64 "${url_aarch64}" \
   --arg sha256_aarch64 "${sha256_aarch64}" \
   --arg url_x86_64 "${url_x86_64}" \
   --arg sha256_x86_64 "${sha256_x86_64}" \
   --arg url_src "${url_src}" \
   --arg sha256_src "${sha256_src}" \
   '.[0] |= (.url = $url_aarch64 | .sha256 = $sha256_aarch64) |
    .[1] |= (.url = $url_x86_64 | .sha256 = $sha256_x86_64) |
    .[2] |= (.url = $url_src | .sha256 = $sha256_src)' sources/rust-nightly.json > sources/rust-nightly.json.tmp
mv sources/rust-nightly.json.tmp sources/rust-nightly.json

# Stash the changes
git stash push -m "Update Ungoogled Chromium to ${ugc_version:?}"

# Fetch org.chromium.Chromium and offer to cherry-pick commits
git remote add org.chromium.Chromium https://github.com/flathub/org.chromium.chromium 2>/dev/null || true
git fetch org.chromium.Chromium master
last_checked_commit=$(cat maint/.org.chromium.Chromium.last_checked_commit)
commits_to_consider=$(git log --pretty='%ae %h %s' --no-merges "${last_checked_commit:?}..org.chromium.Chromium/master" | grep -v '^sysadmin@flathub.org ')
for commit in ${commits_to_consider}; do
    commit_hash=$(printf '%s\n' "${commit}" | awk '{print $2}')
    commit_subject=$(printf '%s\n' "${commit}" | cut -d' ' -f3-)
    while true; do
        echoerr "Apply commit ${commit_hash}: ${commit_subject}? [y/N] "
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

# Create a new commit and push the changes
git add \
    sources/chromium.json \
    sources/ugc.json \
    sources/rust-nightly.json \
    maint/.org.chromium.Chromium.last_checked_commit
git commit -s -m "Update Ungoogled Chromium to ${ugc_version:?}"
git push origin "update-ugc-${ugc_version:?}"

# Exit with success
exit 0
