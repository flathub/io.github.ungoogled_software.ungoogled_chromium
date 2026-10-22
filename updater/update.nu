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
    ^curl -Lf --retry 20 --speed-limit 100 --speed-time 5 -o $tmp ...$args
    open -r $tmp
  } finally {
    rm -f $tmp
  }
}

# finds a Python 'key': 'value' from a dict literal
def get-deps-dict-value [key: string] {
  $in | parse -r $"\(?m)^\\s*'($key)': '\(?<value>[^']+)'" | only value
}

# finds the 'version' of a CIPD 'package' from a DEPS dict literal
def get-deps-cipd-version [package: string] {
  $in | parse -r $"'package': '($package)',\\s*'version': '\(?<value>[^']+)'" | only value
}

# finds the GCS 'object_name' and 'sha256sum' for a DEPS entry
def get-deps-gcs-object [dep: string] {
  $in
  | split row ("'" + $dep + "':")
  | get 1
  | parse -r "(?s)^\\s*\\{.*?'object_name': '(?<name>[^']+)',\\s*'sha256sum': '(?<sha256>[0-9a-f]{64})'"
  | only
}

# parses a node package-lock.json base64 integrity value and turns it into a
# more normal hex digest
def parse-node-sha512 [] {
  let parts = $in | parse '{alg}-{b64}' | only
  if $parts.alg != 'sha512' {
    error make { msg: $'unknown node integrity algorithm: ($parts.alg)' }
  }

  $parts.b64 | decode base64 | encode hex --lower
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

# finds the latest ungoogled-chromium release tag (e.g. 155.0.8059.79-1) and
# the commit it points at
def get-ugc-release [] {
  git ls-remote --tags https://github.com/ungoogled-software/ungoogled-chromium
  | lines
  | parse -r '^(?<commit>[0-9a-f]{40})\s+refs/tags/(?<version>\d+\.\d+\.\d+\.\d+-\d+)(?<peeled>\^\{\})?$'
  | group-by version
  | transpose version entries
  | each {|tag|
    # Prefer the peeled commit of annotated tags.
    let peeled = $tag.entries | where peeled == '^{}'
    {
      version: $tag.version
      commit: (if ($peeled | is-empty) { $tag.entries | only commit } else { $peeled | only commit })
    }
  }
  | sort-by -n version
  | last
}

def is-gha [] {
  'GITHUB_OUTPUT' in $env
}

def github-output [line: string] {
  if (is-gha) {
    $'($line)(char eol)' | save -a $env.GITHUB_OUTPUT
  }
}

def main [--commit] {
  const manifest = path self ../io.github.ungoogled_software.ungoogled_chromium.yaml
  const metainfo = path self ../io.github.ungoogled_software.ungoogled_chromium.metainfo.xml

  let release_info = get-ugc-release
  let ugc_version = $release_info | get version
  let uc_commit = $release_info | get commit
  let chromium_version = $ugc_version | str replace -r '-\d+$' ''
  # Use the release commit's date, so that reruns produce an identical tree.
  let ugc_clone = (mktemp -d)
  git clone -q --depth 1 --branch $ugc_version https://github.com/ungoogled-software/ungoogled-chromium $ugc_clone
  let ugc_time = git -C $ugc_clone log -1 --format=%cI | str trim | into datetime
  rm -rf $ugc_clone
  print $'Ungoogled Chromium version: ($ugc_version) at commit ($uc_commit), released on: ($ugc_time)'
  github-output $'version=($ugc_version)'

  let chromium_url = $'https://github.com/chromium-linux-tarballs/chromium-tarballs/releases/download/($chromium_version)/chromium-($chromium_version)-linux.tar.xz'
  try {
    http ['--head' $chromium_url]
  } catch {|e|
    let exit = ($e | get -o exit_code)
    if $exit != 22 {  # 22: HTTP error from -f
      error make $e  # rethrow
    }

    if (is-gha) {
      print $'::warning:: Chromium tarball is not yet available'
    } else {
      print -e 'Chromium tarball is not yet available'
    }
    exit 1
  }

  let chromium_sha256 = (
    http [$'($chromium_url).hashes']
    | lines
    | split column -r '\s+' alg digest
    | where alg == 'sha256'
    | only digest
  )

  print $'Chromium tarball: ($chromium_url) ($chromium_sha256)'

  let websrc = $'https://chromium.googlesource.com/chromium/src/+/($chromium_version)'

  let clang_update_py = gitiles-src $'($websrc)/tools/clang/scripts/update.py'
  let llvm_revision = $clang_update_py | parse -r "(?m)^CLANG_REVISION = '(?<value>[^']+)'" | only value
  let llvm_sub_revision = $clang_update_py | parse -r '(?m)^CLANG_SUB_REVISION = (?<value>.+)' | only value
  print $'LLVM: ($llvm_revision)-($llvm_sub_revision)'
  let llvm_prebuilt_x64_url = $'https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64/clang-($llvm_revision)-($llvm_sub_revision).tar.xz'
  let llvm_prebuilt_x64_sha256 = http [$llvm_prebuilt_x64_url] | hash sha256
  print $'LLVM x64: ($llvm_prebuilt_x64_url) ($llvm_prebuilt_x64_sha256)'
  let llvm_prebuilt_arm64_url = get-arm64-toolchain-release-url 'clang' $'($llvm_revision)-($llvm_sub_revision)'
  let llvm_prebuilt_arm64_sha256 = http [$'($llvm_prebuilt_arm64_url).sha256'] | lines | parse-sha256-table | only sha256
  print $'LLVM arm64: ($llvm_prebuilt_arm64_url) ($llvm_prebuilt_arm64_sha256)'
  let clang_format_arm64_url = $llvm_prebuilt_arm64_url | str replace -r '/clang-([^/]+)$' '/clang-format-${1}'
  let clang_format_arm64_sha256 = http [$'($clang_format_arm64_url).sha256'] | lines | parse-sha256-table | only sha256
  print $'Clang format arm64: ($clang_format_arm64_url) ($clang_format_arm64_sha256)'

  let rust_update_py = gitiles-src $'($websrc)/tools/rust/update_rust.py'
  let rust_revision = $rust_update_py | parse -r "(?m)^RUST_REVISION = '(?<value>[^']+)'" | only value
  let rust_sub_revision = $rust_update_py | parse -r "(?m)^RUST_SUB_REVISION = (?<value>.+)" | only value
  print $'Rust: ($rust_revision)-($rust_sub_revision)-($llvm_revision)'
  let rust_prebuilt_x64_url = $'https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64/rust-toolchain-($rust_revision)-($rust_sub_revision)-($llvm_revision).tar.xz'
  let rust_prebuilt_x64_sha256 = http [$rust_prebuilt_x64_url] | hash sha256
  print $'Rust x64: ($rust_prebuilt_x64_url) ($rust_prebuilt_x64_sha256)'
  let rust_prebuilt_arm64_url = get-arm64-toolchain-release-url 'rust' $'($rust_revision)-($rust_sub_revision)-($llvm_revision)' 'rust-toolchain'
  let rust_prebuilt_arm64_sha256 = http [$'($rust_prebuilt_arm64_url).sha256'] | lines | parse-sha256-table | only sha256
  print $'Rust arm64: ($rust_prebuilt_arm64_url) ($rust_prebuilt_arm64_sha256)'

  # ungoogled-chromium prunes the bundled libclang, clang-format and TypeScript,
  # so the x64 copies that the Chromium tarball normally provides are also
  # needed.
  let libclang_x64_url = $'https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64/rust-libclang-($rust_revision)-($rust_sub_revision)-($llvm_revision).tar.xz'
  let libclang_x64_sha256 = http [$libclang_x64_url] | hash sha256
  print $'libclang x64: ($libclang_x64_url) ($libclang_x64_sha256)'

  let gclient_deps = gitiles-src $'($websrc)/DEPS'

  let clang_format_x64 = $gclient_deps | get-deps-gcs-object 'src/buildtools/linux64-format'
  let clang_format_x64_url = $'https://commondatastorage.googleapis.com/chromium-clang-format/($clang_format_x64.name)'
  let clang_format_x64_sha256 = $clang_format_x64.sha256
  print $'Clang format x64: ($clang_format_x64_url) ($clang_format_x64_sha256)'

  let ts_x64_version = $gclient_deps | get-deps-cipd-version 'chromium/third_party/typescript/linux-amd64'
  let ts_x64_url = $'https://chrome-infra-packages.appspot.com/dl/chromium/third_party/typescript/linux-amd64/+/($ts_x64_version)'
  let ts_x64_sha256 = cipd-sha256 chromium/third_party/typescript/linux-amd64 $ts_x64_version
  print $'TypeScript x64: ($ts_x64_url) ($ts_x64_sha256)'

  let ts_3pp = gitiles-src $'($websrc)/third_party/typescript/linux-amd64/3pp/3pp.pb'
  let ts_arm64_url = (
    $ts_3pp
    | parse -r '(?m)^\s*download_url: "(?<url>[^"]+)"'
    | only url
    | str replace -ar '\bx64\b' 'arm64'
  )
  let ts_arm64_sha256 = http [$ts_arm64_url] | hash sha256
  print $'TypeScript arm64: ($ts_arm64_url) ($ts_arm64_sha256)'

  let devtools_frontend_revision = $gclient_deps | get-deps-dict-value devtools_frontend_revision
  print $'Devtools frontend revision: ($devtools_frontend_revision)'

  let devtools_package_lock = (
    gitiles-src $'https://chromium.googlesource.com/devtools/devtools-frontend/+/($devtools_frontend_revision)/package-lock.json'
    | from json
  )
  let esbuild_x64_version = $devtools_package_lock.packages.'node_modules/@esbuild/linux-x64'.version
  let esbuild_x64_url = $'https://npm.skia.org/chrome-devtools/@esbuild/linux-x64/-/linux-x64-($esbuild_x64_version).tgz'
  let esbuild_x64_sha512 = (
    $devtools_package_lock.packages.'node_modules/@esbuild/linux-x64'.integrity
    | parse-node-sha512
  )
  let esbuild_arm64_version = $devtools_package_lock.packages.'node_modules/@esbuild/linux-arm64'.version
  let esbuild_arm64_url = $'https://npm.skia.org/chrome-devtools/@esbuild/linux-arm64/-/linux-arm64-($esbuild_arm64_version).tgz'
  let esbuild_arm64_sha512 = (
    $devtools_package_lock.packages.'node_modules/@esbuild/linux-arm64'.integrity
    | parse-node-sha512
  )

  print $'esbuild x64: ($esbuild_x64_url) ($esbuild_x64_sha512)'
  print $'esbuild arm64: ($esbuild_arm64_url) ($esbuild_arm64_sha512)'

  let dawn_revision = $gclient_deps | get-deps-dict-value dawn_revision
  print $'Dawn revision: ($dawn_revision)'

  let dawnsrc = $'https://dawn.googlesource.com/dawn/+/($dawn_revision)'
  let dawn_gclient_deps = gitiles-src $'($dawnsrc)/DEPS'
  let dawn_go_version = $dawn_gclient_deps | get-deps-dict-value dawn_go_version
  print $'Dawn Go version: ($dawn_go_version)'
  let dawn_go_x64_url = $'https://chrome-infra-packages.appspot.com/dl/infra/3pp/tools/go/linux-amd64/+/($dawn_go_version)'
  let dawn_go_x64_sha256 = cipd-sha256 infra/3pp/tools/go/linux-amd64 $dawn_go_version
  let dawn_go_arm64_url = $'https://chrome-infra-packages.appspot.com/dl/infra/3pp/tools/go/linux-arm64/+/($dawn_go_version)'
  let dawn_go_arm64_sha256 = cipd-sha256 infra/3pp/tools/go/linux-arm64 $dawn_go_version

  print $'Dawn Go x64: ($dawn_go_x64_url) ($dawn_go_x64_sha256)'
  print $'Dawn Go arm64: ($dawn_go_arm64_url) ($dawn_go_arm64_sha256)'

  let yaml = $'x-version-data:
  - &uc_commit ($uc_commit)
  - &chromium_url ($chromium_url)
  - &chromium_sha256 ($chromium_sha256)
  - &llvm_prebuilt_x64_url ($llvm_prebuilt_x64_url)
  - &llvm_prebuilt_x64_sha256 ($llvm_prebuilt_x64_sha256)
  - &llvm_prebuilt_arm64_url ($llvm_prebuilt_arm64_url)
  - &llvm_prebuilt_arm64_sha256 ($llvm_prebuilt_arm64_sha256)
  - &clang_format_x64_url ($clang_format_x64_url)
  - &clang_format_x64_sha256 ($clang_format_x64_sha256)
  - &clang_format_arm64_url ($clang_format_arm64_url)
  - &clang_format_arm64_sha256 ($clang_format_arm64_sha256)
  - &rust_prebuilt_x64_url ($rust_prebuilt_x64_url)
  - &rust_prebuilt_x64_sha256 ($rust_prebuilt_x64_sha256)
  - &rust_prebuilt_arm64_url ($rust_prebuilt_arm64_url)
  - &rust_prebuilt_arm64_sha256 ($rust_prebuilt_arm64_sha256)
  - &libclang_x64_url ($libclang_x64_url)
  - &libclang_x64_sha256 ($libclang_x64_sha256)
  - &ts_x64_url ($ts_x64_url)
  - &ts_x64_sha256 ($ts_x64_sha256)
  - &ts_arm64_url ($ts_arm64_url)
  - &ts_arm64_sha256 ($ts_arm64_sha256)
  - &esbuild_x64_url ($esbuild_x64_url)
  - &esbuild_x64_sha512 ($esbuild_x64_sha512)
  - &esbuild_arm64_url ($esbuild_arm64_url)
  - &esbuild_arm64_sha512 ($esbuild_arm64_sha512)
  - &dawn_go_x64_url ($dawn_go_x64_url)
  - &dawn_go_x64_sha256 ($dawn_go_x64_sha256)
  - &dawn_go_arm64_url ($dawn_go_arm64_url)
  - &dawn_go_arm64_sha256 ($dawn_go_arm64_sha256)
'

  let updated_manifest = (
    open -r $manifest
    | decode
    | str replace -rmn '^x-version-data:\n(?: +[^\n]+\n)+' $yaml
  )

  let manifest_tmp = $'($manifest).tmp'
  $updated_manifest | save -f $manifest_tmp
  let has_manifest_diff = try {
    diff -u $manifest $manifest_tmp
    false
  } catch {
    true
  }

  if not $has_manifest_diff {
    rm $manifest_tmp
  }

  let metainfo_tmp = $'($metainfo).tmp'
  let current_metainfo = open -r $metainfo | decode
  let has_metainfo_diff = if not ($current_metainfo
    | str contains $'<release version="($ugc_version)"') {
    let now = $ugc_time | format date "%Y-%m-%d"
    let release = $'
    <release version="($ugc_version)" date="($now)">
      <description/>
    </release>
'
    $current_metainfo | str replace -rmn "(?<=^\\s+<releases>)\n" $release | save -f $metainfo_tmp
    do -i { diff -u $metainfo $metainfo_tmp }
    true
  } else {
    false
  }

  if not ($has_manifest_diff or $has_metainfo_diff) {
    print 'Nothing to do.'
    exit
  }

  if $has_manifest_diff {
    mv $manifest_tmp $manifest
  }

  if $has_metainfo_diff {
    mv $metainfo_tmp $metainfo
  }

  github-output 'changed=yes'

  if $commit {
    git commit -am $'Update Ungoogled Chromium to ($ugc_version)'
    github-output $'short-tree=(git rev-parse --short 'HEAD^{tree}' | str trim)'
  }
}
