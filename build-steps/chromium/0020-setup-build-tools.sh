#!/bin/bash
set -euxo pipefail

ln_overwrite_all() {
	rm -rfv "$2"
	mkdir -pv "$(dirname "$2")"
	ln -svf "$1" "$2"
}

# Disable SDK default flags
# https://gitlab.com/freedesktop-sdk/freedesktop-sdk/-/blob/release/24.08/include/flags.yml
export CFLAGS='' CXXFLAGS='' CPPFLAGS=''
unset LDFLAGS RUSTFLAGS

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

# DevTools bundles JavaScript with esbuild.
devtools_dir=third_party/devtools-frontend/src
ln_overwrite_all /app/toolchains/esbuild "${devtools_dir}/third_party/esbuild"
[[ -x "${devtools_dir}/third_party/esbuild/esbuild" ]]

# Install build-only toolchains after pruning, which removes bundled binaries.
ln_overwrite_all /app/toolchains/llvm third_party/llvm-build/Release+Asserts
ln_overwrite_all /app/toolchains/rust third_party/rust-toolchain
if [[ "${FLATPAK_ARCH}" == "x86_64" ]]; then
	ln_overwrite_all /app/toolchains/libclang third_party/llvm-libclang
else
	# The native Rust toolchain carries the matching libclang built with LLVM.
	ln_overwrite_all /app/toolchains/rust/lib/libclang.so third_party/llvm-libclang/lib/libclang.so
fi
export PATH="${PWD}/third_party/llvm-build/Release+Asserts/bin:${PWD}/third_party/rust-toolchain/bin:/app/toolchains/node/bin:/app/toolchains/go/bin:${JAVA_HOME}/bin:${PATH}"
export CC="${PWD}/third_party/llvm-build/Release+Asserts/bin/clang"
export CXX="${PWD}/third_party/llvm-build/Release+Asserts/bin/clang++"
export AR="${PWD}/third_party/llvm-build/Release+Asserts/bin/llvm-ar"

# Build generators use clang-format even when no formatting is requested.
ln_overwrite_all /app/toolchains/clang-format buildtools/linux64-format/clang-format
[[ -x buildtools/linux64-format/clang-format ]]
buildtools/linux64-format/clang-format --version

# Report the installed compiler versions.
"${CC}" --version
third_party/rust-toolchain/bin/rustc --version
third_party/rust-toolchain/bin/bindgen --version

# Use Google's pinned version: CIPD on x86_64, the same source release on ARM64.
ln_overwrite_all /app/toolchains/gperf third_party/gperf/cipd
third_party/gperf/cipd/bin/gperf --version

# Provide the complete pinned Go distribution for Dawn/Tint generation.
case "${FLATPAK_ARCH}" in
	x86_64) cipd_arch="amd64";;
	aarch64) cipd_arch="arm64";;
	*) echo >&2 "Unsupported architecture: ${FLATPAK_ARCH}"; exit 1;;
esac
ln_overwrite_all /app/toolchains/go "third_party/dawn/tools/golang/linux-${cipd_arch}"
export GOROOT=/app/toolchains/go
export GOTOOLCHAIN=local

third_party/node/linux/node-linux-x64/bin/node --version
"third_party/dawn/tools/golang/linux-${cipd_arch}/bin/go" version
"${JAVA_HOME}/bin/java" -version
"${JAVA_HOME}/bin/javac" -version

# GN does not use Cargo's wrapper. Adapt its explicit output names for sccache.
export RUSTC_WRAPPER="${PWD}/build-steps/rustc-cache.py"
/app/bin/sccache --show-stats
