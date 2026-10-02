#!/bin/bash
set -euxo pipefail

# Match Chromium's tools/rust/build_crubit.py using offline Cargo sources.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
export PATH="/app/toolchains/rust/bin:/app/toolchains/llvm/bin:${PATH}"
export CC=/app/toolchains/llvm/bin/clang
export CXX=/app/toolchains/llvm/bin/clang++
export AR=/app/toolchains/llvm/bin/llvm-ar
export RUSTC=/app/toolchains/rust/bin/rustc
export CARGO_HOME="${PWD}/cargo-home"
export CARGO_NET_OFFLINE=true
# Keep $ORIGIN literal so the installed generator finds librustc_driver.
export RUSTFLAGS='-Clinker=/app/toolchains/llvm/bin/clang -Clink-arg=-fuse-ld=lld -Clink-args=-Wl,-z,origin -Clink-args=-Wl,-rpath,$ORIGIN/../lib'

cd crubit
/app/toolchains/rust/bin/cargo build --offline --locked --release \
    --manifest-path cargo/cc_bindings_from_rs/cc_bindings_from_rs/Cargo.toml \
    --bin cc_bindings_from_rs --target-dir ../crubit-target
install -Dm755 ../crubit-target/release/cc_bindings_from_rs \
    /app/toolchains/rust/bin/cc_bindings_from_rs
mkdir -p /app/toolchains/rust/lib/third_party/crubit
cp -a BUILD.gn LICENSE crubit.gni support /app/toolchains/rust/lib/third_party/crubit/

# Exercise the installed generator, its rustc private libraries and support headers.
mkdir -p ../crubit-smoke
cd ../crubit-smoke
printf '%s\n' 'pub fn add(a: i32, b: i32) -> i32 { a + b }' > crubit_smoke.rs
/app/toolchains/rust/bin/cc_bindings_from_rs \
    --h-out=crubit_smoke.h --rs-out=crubit_smoke_impl.rs \
    --crubit-support-path-format='<third_party/crubit/support/{header}>' \
    --default-features=supported \
    -- --crate-name=crubit_smoke --crate-type=lib --edition=2024 \
    --sysroot=/app/toolchains/rust crubit_smoke.rs
printf '%s\n' '#include "crubit_smoke.h"' \
    'int main() { return crubit_smoke::add(20, 22) != 42; }' > main.cc
"${CXX}" -std=c++20 -I/app/toolchains/rust/lib -fsyntax-only main.cc
