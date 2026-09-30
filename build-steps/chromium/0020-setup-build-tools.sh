#!/bin/bash
set -euxo pipefail

ln_overwrite_all() {
	rm -rfv "$2"
	mkdir -pv "$(dirname "$2")"
	ln -svf "$1" "$2"
}

# Set custom flags and disable SDK defaults
# https://gitlab.com/freedesktop-sdk/freedesktop-sdk/-/blob/release/24.08/include/flags.yml
export CFLAGS='' CXXFLAGS='' CPPFLAGS=''
unset LDFLAGS RUSTFLAGS

# Facilitate deterministic builds (taken from build/config/compiler/BUILD.gn)
CFLAGS+='   -Wno-builtin-macro-redefined'
CXXFLAGS+=' -Wno-builtin-macro-redefined'
CPPFLAGS+=' -D__DATE__=  -D__TIME__=  -D__TIMESTAMP__='

# Do not warn about unknown warning options
CFLAGS+='   -Wno-unknown-warning-option'
CXXFLAGS+=' -Wno-unknown-warning-option'

# Restore the pinned Node and JDK binaries after pruning.
ln_overwrite_all /app/toolchains/node third_party/node/linux/node-linux-x64
export JAVA_HOME=/app/toolchains/jdk
ln_overwrite_all "${JAVA_HOME}" third_party/jdk/current

# Restore TypeScript after pruning, retaining Chromium's patched declarations.
# Chromium uses this directory on all Linux hosts, including ARM64.
# Copy it into the source tree: tsc resolves symlinks, and Chromium's dependency
# validator only recognizes standard declarations under third_party/typescript.
rm -rfv third_party/typescript/linux-amd64/src
mkdir -pv third_party/typescript/linux-amd64/src
cp -a /app/toolchains/typescript/. third_party/typescript/linux-amd64/src/
[[ -x third_party/typescript/linux-amd64/src/lib/tsc ]]

# DevTools bundles JS with esbuild and loads Rollup's native Node addon.
devtools_dir=third_party/devtools-frontend/src
ln_overwrite_all /app/toolchains/esbuild "${devtools_dir}/third_party/esbuild"
ln_overwrite_all /app/toolchains/rollup_libs "${devtools_dir}/third_party/rollup_libs"
(cd "${devtools_dir}" && python3 scripts/deps/sync_rollup_libs.py)
[[ -x "${devtools_dir}/third_party/esbuild/esbuild" ]]

# Install build-only toolchains after pruning, which removes bundled binaries.
ln_overwrite_all /app/toolchains/llvm third_party/llvm-build/Release+Asserts
ln_overwrite_all /app/toolchains/rust third_party/rust-toolchain
if [[ "${FLATPAK_ARCH}" == "x86_64" ]]; then
	ln_overwrite_all /app/toolchains/libclang third_party/llvm-libclang
fi
export PATH="${PWD}/third_party/llvm-build/Release+Asserts/bin:${PWD}/third_party/rust-toolchain/bin:/app/toolchains/node/bin:/app/toolchains/go/bin:${JAVA_HOME}/bin:${PATH}"
export CC="${PWD}/third_party/llvm-build/Release+Asserts/bin/clang"
export CXX="${PWD}/third_party/llvm-build/Release+Asserts/bin/clang++"
export AR="${PWD}/third_party/llvm-build/Release+Asserts/bin/llvm-ar"

# Build generators use clang-format even when no formatting is requested.
ln_overwrite_all /app/toolchains/clang-format buildtools/linux64-format/clang-format
[[ -x buildtools/linux64-format/clang-format ]]
buildtools/linux64-format/clang-format --version

# Fail early if release metadata and the supplied tools have drifted apart.
python3 tools/clang/scripts/update.py --print-revision
python3 tools/rust/update_rust.py --print-revision validate
"${CC}" --version
third_party/rust-toolchain/bin/rustc --version
third_party/rust-toolchain/bin/bindgen --version

# To use correct gperf binary
gperf_path=$(command -v gperf)
if [[ -z "${gperf_path}" ]]; then
	echo 'Error: gperf not found in PATH' >&2
	exit 1
fi
rm -rfv third_party/gperf/cipd/bin/
mkdir -pv third_party/gperf/cipd/bin/
ln -svf "${gperf_path}" third_party/gperf/cipd/bin/

# Provide the complete pinned Go distribution for Dawn/Tint generation.
case "${FLATPAK_ARCH}" in
	x86_64) cipd_arch="amd64";;
	aarch64) cipd_arch="arm64";;
	*) echo >&2 "Unsupported architecture: ${FLATPAK_ARCH}"; exit 1;;
esac
ln_overwrite_all /app/toolchains/go "third_party/dawn/tools/golang/linux-${cipd_arch}"
export GOROOT=/app/toolchains/go
export GOTOOLCHAIN=local

node_version=$(third_party/node/linux/node-linux-x64/bin/node --version)
go_version=$("third_party/dawn/tools/golang/linux-${cipd_arch}/bin/go" version)
[[ "${node_version}" == "$(cat /app/toolchains/node-version)" ]]
[[ "${go_version}" == "go version $(cat /app/toolchains/go-version) linux/${cipd_arch}" ]]
grep -Fx "SEMANTIC_VERSION=\"$(cat /app/toolchains/jdk-version)\"" "${JAVA_HOME}/release"
"${JAVA_HOME}/bin/java" -version
"${JAVA_HOME}/bin/javac" -version
