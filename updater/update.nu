#!/usr/bin/env nu

# https://github.com/nushell/nushell/pull/16015
# but simplified
def only [path?: cell-path]: [table -> any, list -> any] {
  if ($in | length) != 1 {
    print ($in | debug)
    error make { msg: "expected exactly one element" }
  } else if $path != null {
    $in | get 0 | get $path
  } else {
    $in | get 0
  }
}

def http [args: list<string>] {
  # Use a temporary file, so that curl can clear it on retries, and we don't end
  # up wih mixed output from previous attempts.
  let tmp = (mktemp)
  try {
    ^curl -LfsS --retry 20 --connect-timeout 30 --speed-limit 100 --speed-time 5 -o $tmp ...$args
    open -r $tmp
  } finally {
    rm -f $tmp
  }
}

# finds a Python 'key': 'value' from a dict literal
def get-deps-dict-value [key: string] {
  $in | parse -r $"\(?m)^\\s*'($key)': '\(?<value>[^']+)'" | only value
}

def parse-sha256-table [] {
  $in | split column -r '\s+' sha256 filename
}

def cipd-sha256 [p: string, v: string] {
  let data = ({package: $p, version: $v} | to json)
  let instance = (
    http [
      -H 'Content-Type: application/json' -H 'Accept: application/json'
      --data $data
      'https://chrome-infra-packages.appspot.com/prpc/cipd.Repository/ResolveVersion'
    ]
    | str replace -rm "^\\)\\]\\}'$" '' # strip the XSSI prefix
    | from json
    | get instance
  )

  if $instance.hashAlgo != 'SHA256' {
    error make { msg: $'unknown hashAlgo: ($instance.hashAlgo)' }
  }

  $instance.hexDigest
}

def gitiles-src [path: string] {
  http [$'($path)?format=TEXT'] | decode base64 | decode
}

def get-arm64-toolchain-release-url [
  release_prefix: string
  revision: string
  filename_prefix?: string
] {
  let release = (
    git ls-remote --tags https://github.com/refi64/cr-toolchain-arm64 $'($release_prefix)-($revision)-*'
    | lines
    | parse -r '^\S+\s+refs/tags/(?<release>[^\s^]+)$'
    | sort -n
    | last -s
    | get release
  )

  mut filename = $'($release).tar.xz'
  if $filename_prefix != null {
    $filename = $filename | str replace -r $'^($release_prefix)' $filename_prefix
  }

  $'https://github.com/refi64/cr-toolchain-arm64/releases/download/($release)/($filename)'
}

def is-gha [] {
  'GITHUB_OUTPUT' in $env
}

def github-output [line: string] {
  if (is-gha) {
    $'($line)(char eol)' | save -a $env.GITHUB_OUTPUT
  }
}

# UGC releases include a package revision (for example 155.0.8059.39-1).
def ugc-tags [] {
  git ls-remote --tags https://github.com/ungoogled-software/ungoogled-chromium
  | lines
  | parse -r '^(?<commit>[0-9a-f]{40})\s+refs/tags/(?<version>\d+\.\d+\.\d+\.\d+-\d+)(?<peeled>\^\{\})?$'
  | group-by version
  | transpose version entries
  | each {|tag|
    let peeled = $tag.entries | where peeled == '^{}'
    {
      version: $tag.version
      commit: (if ($peeled | is-empty) { $tag.entries | first | get commit } else { $peeled | only commit })
    }
  }
  | sort-by -nr version
}

def source-release [version: string, commit: string] {
  let chromium = $version | str replace -r '-\d+$' ''
  let url = $'https://github.com/chromium-linux-tarballs/chromium-tarballs/releases/download/($chromium)/chromium-($chromium)-linux.tar.xz'
  let status = (
    ^curl -sSL --retry 20 --connect-timeout 30 --speed-limit 100 --speed-time 5 --head --output /dev/null --write-out '%{http_code}' $url
    | into int
  )
  if $status == 404 { return null }
  if $status != 200 { error make {msg: $'Source archive returned HTTP ($status): ($url)'} }
  let sha256 = http [$'($url).hashes'] | lines | split column -r '\s+' alg digest | where alg == sha256 | only digest
  if $sha256 !~ '^[0-9a-fA-F]{64}$' { error make {msg: 'Invalid source SHA256'} }
  {version: $version, commit: $commit, chromium: $chromium, url: $url, sha256: ($sha256 | str lowercase)}
}

# Additional archives used by UGC are already checksummed in Chromium's DEPS.
def gcs-objects [] {
  $in | parse -r "'object_name': '(?<name>[^']+)',\\s*'sha256sum': '(?<sha256>[0-9a-f]{64})'"
}

def deps-package [name: string] {
  $in | parse -r "'package': '(?<package>[^']+)',\\s*'version': '(?<version>[^']+)'"
  | where package == $name | only
}

def main [version?: string, uc_commit?: string, --commit, --dry-run] {
  const root = path self ..
  const manifest = path self ../io.github.ungoogled_software.ungoogled_chromium.yaml
  const metainfo = path self ../io.github.ungoogled_software.ungoogled_chromium.metainfo.xml
  let manifest_text = open -r $manifest | decode
  let metainfo_text = open -r $metainfo | decode
  let current = $metainfo_text | parse -r '<release version="(?<version>[^" ]+)"' | get version | sort -n | last
  let candidates = if $version != null {
    if $version !~ '^\d+\.\d+\.\d+\.\d+-\d+$' { error make {msg: 'Invalid UGC version'} }
    [{version: $version, commit: (if $uc_commit != null { $uc_commit } else { ugc-tags | where version == $version | only commit })}]
  } else {
    ugc-tags | where {|tag| $tag.version != $current and ([$current $tag.version] | sort -n | last) == $tag.version }
  }
  mut selected: any = null
  for candidate in $candidates {
    if $candidate.commit !~ '^[0-9a-f]{40}$' { error make {msg: 'Expected a full UGC commit SHA'} }
    $selected = source-release $candidate.version $candidate.commit
    if $selected != null { break }
    print $'Waiting for Linux sources for ($candidate.version)'
  }
  if $selected == null {
    if $version != null { error make {msg: $'Linux sources are unavailable for ($version)'} }
    print $'No ready update newer than ($current)'
    return
  }
  let ugc_version = $selected.version
  let chromium_version = $selected.chromium
  print $'Update: ($current) -> ($ugc_version) (($selected.commit))'
  if $dry_run { return }

  let websrc = $'https://chromium.googlesource.com/chromium/src/+/($chromium_version)'
  let gclient_deps = gitiles-src $'($websrc)/DEPS'
  let objects = $gclient_deps | gcs-objects
  let clang_update_py = gitiles-src $'($websrc)/tools/clang/scripts/update.py'
  let llvm_revision = $clang_update_py | parse -r "(?m)^CLANG_REVISION = '(?<value>[^']+)'" | only value
  let llvm_sub_revision = $clang_update_py | parse -r '(?m)^CLANG_SUB_REVISION = (?<value>.+)' | only value
  let clang_package = $'($llvm_revision)-($llvm_sub_revision)'
  let rust_update_py = gitiles-src $'($websrc)/tools/rust/update_rust.py'
  let rust_revision = $rust_update_py | parse -r "(?m)^RUST_REVISION = '(?<value>[^']+)'" | only value
  let rust_sub_revision = $rust_update_py | parse -r '(?m)^RUST_SUB_REVISION = (?<value>.+)' | only value
  let rust_package = $'($rust_revision)-($rust_sub_revision)-($llvm_revision)'

  let llvm_prebuilt_x64_url = $'https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64/clang-($clang_package).tar.xz'
  let llvm_prebuilt_x64_sha256 = $objects | where name == $'Linux_x64/clang-($clang_package).tar.xz' | only sha256
  let llvmobjdump_x64_url = $'https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64/llvmobjdump-($clang_package).tar.xz'
  let llvmobjdump_x64_sha256 = $objects | where name == $'Linux_x64/llvmobjdump-($clang_package).tar.xz' | only sha256
  let rust_prebuilt_x64_url = $'https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64/rust-toolchain-($rust_package).tar.xz'
  let rust_prebuilt_x64_sha256 = $objects | where name == $'Linux_x64/rust-toolchain-($rust_package).tar.xz' | only sha256
  let libclang_x64_url = $'https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64/rust-libclang-($rust_package).tar.xz'
  let libclang_x64_sha256 = $objects | where name == $'Linux_x64/rust-libclang-($rust_package).tar.xz' | only sha256

  let llvm_prebuilt_arm64_url = get-arm64-toolchain-release-url clang $clang_package
  let llvm_prebuilt_arm64_sha256 = http [$'($llvm_prebuilt_arm64_url).sha256'] | lines | parse-sha256-table | only sha256
  let clang_format_arm64_url = $llvm_prebuilt_arm64_url | str replace -r '/clang-([^/]+)$' '/clang-format-${1}'
  let clang_format_arm64_sha256 = http [$'($clang_format_arm64_url).sha256'] | lines | parse-sha256-table | only sha256
  let rust_prebuilt_arm64_url = get-arm64-toolchain-release-url rust $rust_package rust-toolchain
  let rust_prebuilt_arm64_sha256 = http [$'($rust_prebuilt_arm64_url).sha256'] | lines | parse-sha256-table | only sha256
  for url in [$llvm_prebuilt_arm64_url $clang_format_arm64_url $rust_prebuilt_arm64_url] { http [--head $url] | ignore }

  let ts_3pp = gitiles-src $'($websrc)/third_party/typescript/linux-amd64/3pp/3pp.pb'
  let ts_arm64_url = $ts_3pp | parse -r '(?m)^\s*download_url: "(?<url>[^"]+)"' | only url | str replace -ar '\bx64\b' 'arm64'
  let ts_arm64_sha256 = http [$ts_arm64_url] | hash sha256
  let ts_package = $gclient_deps | deps-package chromium/third_party/typescript/linux-amd64
  let ts_version = $ts_package.version | parse 'version:{revision}@{version}' | only version
  if not ($ts_arm64_url | str ends-with $'-($ts_version).tgz') { error make {msg: 'TypeScript source and package versions disagree'} }
  let ts_x64_url = $'https://chrome-infra-packages.appspot.com/dl/($ts_package.package)/+/($ts_package.version)'
  let ts_x64_sha256 = cipd-sha256 $ts_package.package $ts_package.version

  let devtools_frontend_revision = $gclient_deps | get-deps-dict-value devtools_frontend_revision
  let devtools_deps = gitiles-src $'https://chromium.googlesource.com/devtools/devtools-frontend/+/($devtools_frontend_revision)/DEPS'
  let esbuild = $devtools_deps | deps-package 'infra/3pp/tools/esbuild/${{platform}}'
  let esbuild_x64_url = $'https://chrome-infra-packages.appspot.com/dl/infra/3pp/tools/esbuild/linux-amd64/+/($esbuild.version)'
  let esbuild_arm64_url = $'https://chrome-infra-packages.appspot.com/dl/infra/3pp/tools/esbuild/linux-arm64/+/($esbuild.version)'
  let esbuild_x64_sha256 = cipd-sha256 infra/3pp/tools/esbuild/linux-amd64 $esbuild.version
  let esbuild_arm64_sha256 = cipd-sha256 infra/3pp/tools/esbuild/linux-arm64 $esbuild.version

  let dawn_revision = $gclient_deps | get-deps-dict-value dawn_revision
  let dawn_deps = gitiles-src $'https://dawn.googlesource.com/dawn/+/($dawn_revision)/DEPS'
  let dawn_go_version = $dawn_deps | get-deps-dict-value dawn_go_version
  let dawn_go_x64_url = $'https://chrome-infra-packages.appspot.com/dl/infra/3pp/tools/go/linux-amd64/+/($dawn_go_version)'
  let dawn_go_arm64_url = $'https://chrome-infra-packages.appspot.com/dl/infra/3pp/tools/go/linux-arm64/+/($dawn_go_version)'
  let dawn_go_x64_sha256 = cipd-sha256 infra/3pp/tools/go/linux-amd64 $dawn_go_version
  let dawn_go_arm64_sha256 = cipd-sha256 infra/3pp/tools/go/linux-arm64 $dawn_go_version
  let formatter = $gclient_deps | split row "'src/buildtools/linux64-format':" | get 1 | split row "\n  }," | first | gcs-objects | only

  let pins = {
    uc_commit: $selected.commit
    chromium_url: $selected.url
    chromium_sha256: $selected.sha256
    clang_revision: $'($clang_package)(char eol)'
    llvm_prebuilt_x64_url: $llvm_prebuilt_x64_url, llvm_prebuilt_x64_sha256: $llvm_prebuilt_x64_sha256
    llvmobjdump_x64_url: $llvmobjdump_x64_url, llvmobjdump_x64_sha256: $llvmobjdump_x64_sha256
    rust_prebuilt_x64_url: $rust_prebuilt_x64_url, rust_prebuilt_x64_sha256: $rust_prebuilt_x64_sha256
    libclang_x64_url: $libclang_x64_url, libclang_x64_sha256: $libclang_x64_sha256
    llvm_prebuilt_arm64_url: $llvm_prebuilt_arm64_url, llvm_prebuilt_arm64_sha256: $llvm_prebuilt_arm64_sha256
    clang_format_arm64_url: $clang_format_arm64_url, clang_format_arm64_sha256: $clang_format_arm64_sha256
    rust_prebuilt_arm64_url: $rust_prebuilt_arm64_url, rust_prebuilt_arm64_sha256: $rust_prebuilt_arm64_sha256
    dawn_go_x64_url: $dawn_go_x64_url, dawn_go_x64_sha256: $dawn_go_x64_sha256
    dawn_go_arm64_url: $dawn_go_arm64_url, dawn_go_arm64_sha256: $dawn_go_arm64_sha256
    ts_x64_url: $ts_x64_url, ts_x64_sha256: $ts_x64_sha256
    ts_arm64_url: $ts_arm64_url, ts_arm64_sha256: $ts_arm64_sha256
    esbuild_x64_url: $esbuild_x64_url, esbuild_x64_sha256: $esbuild_x64_sha256
    esbuild_arm64_url: $esbuild_arm64_url, esbuild_arm64_sha256: $esbuild_arm64_sha256
    clang_format_x64_url: $'https://commondatastorage.googleapis.com/chromium-clang-format/($formatter.name)'
    clang_format_x64_sha256: $formatter.sha256
  }
  for key in ($pins | columns | where {|key| $key | str ends-with _sha256 }) {
    if ($pins | get $key) !~ '^[0-9a-f]{64}$' { error make {msg: $'Invalid SHA256 for ($key)'} }
  }
  let block = $manifest_text | parse -r '(?m)(?<block>^x-version-data:\n(?:  .+\n)+)' | only block
  let keys = $block | lines | skip 1 | parse '  - &{key} {value}' | get key
  if ($keys | sort) != ($pins | columns | sort) { error make {msg: 'Version-data keys do not match the manifest'} }
  let yaml = "x-version-data:\n" + ($keys | each {|key| $'  - &($key) ($pins | get $key | to json -r)(char eol)' } | str join)
  let updated_manifest = $manifest_text | str replace $block $yaml
  let updated_metainfo = if ($metainfo_text | str contains $'<release version="($ugc_version)"') {
    $metainfo_text
  } else {
    let now = date now | date to-timezone UTC | format date '%Y-%m-%d'
    $metainfo_text | str replace "<releases>\n" $'<releases>(char eol)    <release version="($ugc_version)" date="($now)" />(char eol)'
  }
  if $updated_manifest == $manifest_text and $updated_metainfo == $metainfo_text {
    print 'Nothing to do.'
    return
  }
  if $updated_manifest != $manifest_text { $updated_manifest | save -f $manifest }
  if $updated_metainfo != $metainfo_text { $updated_metainfo | save -f $metainfo }
  github-output 'changed=yes'
  github-output $'version=($ugc_version)'
  if $commit {
    git -C $root add -- $manifest $metainfo
    git -C $root commit -m $'Update Ungoogled Chromium to ($ugc_version)'
    github-output $'short-tree=(git -C $root rev-parse --short 'HEAD^{tree}' | str trim)'
  }
}
