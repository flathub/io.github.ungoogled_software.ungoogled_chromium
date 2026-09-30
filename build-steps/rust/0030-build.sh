#!/bin/bash
set -euxo pipefail

unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS RUSTFLAGS
export PATH="/app/toolchains/llvm/bin:${PATH}"
export CC=/app/toolchains/llvm/bin/clang
export CXX=/app/toolchains/llvm/bin/clang++
export AR=/app/toolchains/llvm/bin/llvm-ar
export RANLIB=/app/toolchains/llvm/bin/llvm-ranlib
export CARGO_HOME="${PWD}/cargo-home"
export CARGO_NET_OFFLINE=true

cat > rust/bootstrap.toml <<EOF
change-id = "ignore"
[llvm]
download-ci-llvm = false
static-libstdcpp = true
[rust]
download-rustc = false
channel = "nightly"
[build]
description = "$(cat rust-revision) chromium"
build = "aarch64-unknown-linux-gnu"
host = ["aarch64-unknown-linux-gnu"]
target = ["aarch64-unknown-linux-gnu"]
rustc = "${PWD}/bootstrap/bin/rustc"
cargo = "${PWD}/bootstrap/bin/cargo"
vendor = true
locked-deps = true
submodules = false
docs = false
profiler = true
extended = true
tools = ["rustfmt", "src"]
[install]
prefix = "/app/toolchains/rust"
sysconfdir = "etc"
[target.aarch64-unknown-linux-gnu]
llvm-config = "/app/toolchains/llvm/bin/llvm-config"
cc = "/app/toolchains/llvm/bin/clang"
cxx = "/app/toolchains/llvm/bin/clang++"
ar = "/app/toolchains/llvm/bin/llvm-ar"
ranlib = "/app/toolchains/llvm/bin/llvm-ranlib"
linker = "/app/toolchains/llvm/bin/clang"
EOF

cd rust
python3 x.py install --stage 2 --jobs "${FLATPAK_BUILDER_N_JOBS}"
cd ..

# Chromium consumes the stdlib source and its vendored dependencies directly.
cp -a vendor /app/toolchains/rust/lib/rustlib/src/rust/library/vendor
printf 'rustc %s %s (%s chromium)\n' \
    "$(cat rust/src/version)" "$(cat rust-commit)" "$(cat rust-revision)" \
    > /app/toolchains/rust/VERSION

# Build Chromium's pinned bindgen against the newly built Rust and libclang.
export RUSTC=/app/toolchains/rust/bin/rustc
export RUSTFLAGS='-Clinker=/app/toolchains/llvm/bin/clang -Clink-arg=-fuse-ld=lld'
export LIBCLANG_PATH=/app/toolchains/llvm/lib
cd bindgen
../bootstrap/bin/cargo build --target-dir ../bindgen-target \
    --offline --locked --release --bin bindgen
cd ..
install -Dm755 bindgen-target/release/bindgen /app/toolchains/rust/bin/bindgen
cp -a /app/toolchains/llvm/lib/libclang.so* /app/toolchains/rust/lib/
ln -s lib /app/toolchains/rust/lib64
