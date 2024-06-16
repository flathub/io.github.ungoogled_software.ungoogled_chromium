#!/bin/sh

# Fail on error
set -e

# Fail on unset variables
set -u

# UGC version is {chromium_version}-{ugc_revision}
ugc_version=${1:?}
chromium_version=${ugc_version%-*}
echo "UGC version: ${ugc_version:?}"
echo "Chromium version: ${chromium_version:?}"

# Create a new branch from the latest master
git fetch origin master
git checkout -b "update-ugc-${ugc_version:?}" origin/master

# Extract the LLVM version from the update.py script
clang_update_script=$(curl -L -s -f "https://chromium.googlesource.com/chromium/src/+/${chromium_version}/tools/clang/scripts/update.py?format=TEXT" | base64 -d)
clang_version=$(printf %s "${clang_update_script:?}" | grep -oP "CLANG_REVISION = '(.*?)'" | cut -d"'" -f2) # llvmorg-19-init-9433-g76ea5feb
clang_subversion=$(printf %s "${clang_update_script:?}" | grep -oP "CLANG_SUB_REVISION = (\d+)" | cut -d' ' -f3) # 1
echo "Clang version: ${clang_version:?}"
echo "Clang subversion: ${clang_subversion:?}"

# Extract the SHA256 hash of the Clang x64 tarball
clang_tarball_url="https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64/clang-${clang_version}-${clang_subversion}.tar.xz"
clang_sha256=$(curl -L -s -f "${clang_tarball_url:?}" | sha256sum | cut -d' ' -f1)
echo "Clang tarball URL: ${clang_tarball_url:?}"
echo "Clang tarball SHA256: ${clang_sha256:?}"

# Get the Chromium SHA256 hash
chromium_url="https://commondatastorage.googleapis.com/chromium-browser-official/chromium-${chromium_version}.tar.xz"
chromium_sha256=$(curl -L -s -f "${chromium_url:?}.hashes" | grep -iE '^sha256\s+' | awk '{print $2}')
echo "Chromium URL: ${chromium_url:?}"
echo "Chromium SHA256: ${chromium_sha256:?}"

# Get the UGC tag and commit
ugc_url=$(jq -r '.[0].url' sources/ugc.json)
ugc_tag=${ugc_version:?}
ugc_commit=$(git ls-remote --tags "${ugc_url:?}" "refs/tags/${ugc_tag:?}" | cut -f1)
echo "UGC tag: ${ugc_tag:?}"
echo "UGC commit: ${ugc_commit:?}"

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

# Pull changes from the org.chromium.Chromium remote
git remote add org.chromium.Chromium https://github.com/flathub/org.chromium.chromium 2>/dev/null || true
git fetch org.chromium.Chromium master
last_checked_commit=$(cat maint/.org.chromium.Chromium.last_checked_commit)
commits_to_consider=$(git log --pretty='%ae %h %s' --no-merges "${last_checked_commit:?}..org.chromium.Chromium/master" | grep -v '^sysadmin@flathub.org ')
for commit in ${commits_to_consider}; do
    commit_hash=$(printf '%s\n' "${commit}" | awk '{print $2}')
    commit_subject=$(printf '%s\n' "${commit}" | cut -d' ' -f3-)
    echo "Apply commit ${commit_hash}: ${commit_subject}? [y/N] "
    read -r REPLY
    if [ "${REPLY}" = "y" ] || [ "${REPLY}" = "Y" ]; then
        git cherry-pick -xs "${commit_hash:?}"
    fi
    echo "${commit_hash:?}" > maint/.org.chromium.Chromium.last_checked_commit
done

# Create a new commit and push the changes
git add sources/chromium.json sources/ugc.json maint/.org.chromium.Chromium.last_checked_commit
git commit -s -m "Update Ungoogled Chromium to ${ugc_version:?}"
git push origin "update-ugc-${ugc_version:?}"

# Exit with success
exit 0
