#!/bin/bash
set -euxo pipefail

unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
export PATH="/app/toolchains/llvm/bin:${PATH}"
export CC=/app/toolchains/llvm/bin/clang
export CXX=/app/toolchains/llvm/bin/clang++
export AR=/app/toolchains/llvm/bin/llvm-ar
export RANLIB=/app/toolchains/llvm/bin/llvm-ranlib
export CARGO_HOME="${PWD}/cargo-home"
export CARGO_NET_OFFLINE=true

# Match the Linux linker settings in Chromium's XPy environment.
export RUSTFLAGS_BOOTSTRAP='-Clink-arg=-fuse-ld=lld -Clink-arg=-Wl,--undefined-version'
export RUSTFLAGS_NOT_BOOTSTRAP="${RUSTFLAGS_BOOTSTRAP}"
export RUSTDOCFLAGS='-Clinker=/app/toolchains/llvm/bin/clang'
export LD=/app/toolchains/llvm/bin/clang

# Crubit uses rustc_private: stage 1 has stage0-built compiler libraries,
# which may not be ABI-compatible with code built by the new compiler.
cd rust
python3 x.py install --stage 2 --jobs "${FLATPAK_BUILDER_N_JOBS}"
cd ..

# Reuse the pinned prebuilt Cargo that drives compiler bootstrap instead
# of compiling another Cargo from source. RUSTC below
# selects the newly installed compiler for bindgen and Crubit.
install -Dm755 bootstrap/bin/cargo /app/toolchains/rust/bin/cargo

# Chromium consumes the stdlib source and its vendored dependencies directly.
cp -a vendor /app/toolchains/rust/lib/rustlib/src/rust/library/vendor
printf 'rustc %s %s (%s chromium)\n' \
    "$(cat rust/src/version)" "$(cat rust-commit)" "$(cat rust-revision)" \
    > /app/toolchains/rust/VERSION

# Build Chromium's pinned bindgen against the newly built Rust and libclang.
export RUSTC=/app/toolchains/rust/bin/rustc
export RUSTFLAGS='-Clinker=/app/toolchains/llvm/bin/clang -Clink-arg=-fuse-ld=lld'
export LIBCLANG_PATH=/app/toolchains/llvm/lib
export LIBCLANG_STATIC_PATH=/app/toolchains/llvm/lib
cd bindgen
/app/toolchains/rust/bin/cargo build --target-dir ../bindgen-target \
    --offline --locked --release --bin bindgen \
    --no-default-features --features=logging,static
cd ..
install -Dm755 bindgen-target/release/bindgen /app/toolchains/rust/bin/bindgen
cp -a /app/toolchains/llvm/lib/libclang.so* /app/toolchains/rust/lib/
ln -s lib /app/toolchains/rust/lib64
