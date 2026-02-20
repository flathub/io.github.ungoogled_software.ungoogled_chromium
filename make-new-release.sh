#!/usr/bin/env bash
set -euxo pipefail

die() {
  echo >&2 "$@"
  exit 1
}

# shellcheck disable=SC2034
SED_BINARIES=(gsed sed)

if [[ $# -ne 1 ]]; then
  die "Usage: $0 <version>   (e.g. 145.0.7632.109-1)"
fi

VERSION="$1"
CHROMIUM_VERSION="${VERSION%-*}"   # strip pkgrel (-1) for tarball version
DATE="$(date -u -I)"

METAFILE="io.github.ungoogled_software.ungoogled_chromium.metainfo.xml"
YAMLFILE="io.github.ungoogled_software.ungoogled_chromium.yaml"

COMMIT_MSG="Update Ungoogled Chromium to ${VERSION}"

choose_and_run() {
  local -n binaries="$1"
  shift

  local binary
  for binary in "${binaries[@]}"; do
    if command -v "${binary}" &>/dev/null; then
      "${binary}" "$@"
      return
    fi
  done

  die "No suitable binary found for: ${binaries[*]}"
}

for cmd in git curl awk; do
  command -v "$cmd" &>/dev/null || die "Missing required command: $cmd"
done

[[ -f "$METAFILE" ]] || die "Missing file: $METAFILE"
[[ -f "$YAMLFILE"  ]] || die "Missing file: $YAMLFILE"

# 1) Find the ungoogled-chromium commit for the release tag
UC_REMOTE="https://github.com/ungoogled-software/ungoogled-chromium"
UC_COMMIT="$(
  git ls-remote --tags "$UC_REMOTE" "refs/tags/${VERSION}" "refs/tags/${VERSION}^{}" |
    awk '
      /\^\{\}$/ {print $1; found=1; exit}
      {first=$1}
      END { if(!found && first!="") print first }
    '
)"
[[ -n "$UC_COMMIT" ]] || die "Could not find tag '${VERSION}' in $UC_REMOTE"

# 2) Compute chromium tarball URL + sha256 from the .hashes file
TARBALL_URL="https://commondatastorage.googleapis.com/chromium-browser-official/chromium-${CHROMIUM_VERSION}-lite.tar.xz"
HASHES_URL="${TARBALL_URL}.hashes"

SHA256="$(
  curl -fsSL "$HASHES_URL" |
    awk '$1=="sha256" {print $2; exit}'
)"
[[ -n "$SHA256" ]] || die "Could not extract sha256 from: $HASHES_URL"

# 3) Update metainfo.xml (insert new <release .../> right after <releases>)
choose_and_run SED_BINARIES -i "/<releases>/a \\
    <release version=\"${VERSION}\" date=\"${DATE}\" />" "${METAFILE}"

# 4) Update YAML: ungoogled-chromium git commit, chromium tarball url, and sha256
tmp="$(mktemp)"
awk -v new_commit="$UC_COMMIT" -v new_url="$TARBALL_URL" -v new_sha="$SHA256" '
  BEGIN {
    seen_uc_url=0
    in_archive=0
    chromium_archive=0
  }

  {
    # --- Update commit right after the ungoogled-chromium URL ---
    if ($0 ~ /url: https:\/\/github\.com\/ungoogled-software\/ungoogled-chromium[[:space:]]*$/) {
      seen_uc_url=1
      print
      next
    }
    if (seen_uc_url && $0 ~ /^[[:space:]]*commit:[[:space:]]*/) {
      indent=$0; sub(/commit:.*/, "", indent)
      print indent "commit: " new_commit
      seen_uc_url=0
      next
    }

    # --- Track archive blocks ---
    # Start of a new archive source entry
    if ($0 ~ /^[[:space:]]*- type:[[:space:]]*archive[[:space:]]*$/) {
      in_archive=1
      chromium_archive=0
      print
      next
    }

    # If we hit a new "- type:" entry (of any kind), we are no longer in the previous archive
    if ($0 ~ /^[[:space:]]*- type:[[:space:]]*/ && $0 !~ /^[[:space:]]*- type:[[:space:]]*archive[[:space:]]*$/) {
      in_archive=0
      chromium_archive=0
      print
      next
    }

    # Inside an archive block: update only the chromium official tarball URL
    if (in_archive && $0 ~ /url: https:\/\/commondatastorage\.googleapis\.com\/chromium-browser-official\/chromium-.*-lite\.tar\.xz[[:space:]]*$/) {
      indent=$0; sub(/url:.*/, "", indent)
      print indent "url: " new_url
      chromium_archive=1
      next
    }

    # Update sha256 ONLY for the chromium tarball archive block
    if (in_archive && chromium_archive && $0 ~ /^[[:space:]]*sha256:[[:space:]]*/) {
      indent=$0; sub(/sha256:.*/, "", indent)
      print indent "sha256: " new_sha
      # done with this archive block
      chromium_archive=0
      next
    }

    print
  }
' "$YAMLFILE" >"$tmp"
mv "$tmp" "$YAMLFILE"

git add "$METAFILE" "$YAMLFILE"
git commit -sm "$COMMIT_MSG"
