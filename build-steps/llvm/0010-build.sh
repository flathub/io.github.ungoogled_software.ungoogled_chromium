#!/bin/bash
set -euxo pipefail

# The LLVM 22 SDK extension builds the pinned LLVM directly. Building an
# intermediate Clang from the same checkout only adds a full compiler build.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
export PATH="/usr/lib/sdk/llvm22/bin:${PATH}"
/usr/lib/sdk/llvm22/bin/clang --version
/usr/lib/sdk/llvm22/bin/ld.lld --version
cmake -S llvm/llvm -B build -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER_LAUNCHER=/app/bin/sccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=/app/bin/sccache \
    -DCMAKE_INSTALL_PREFIX=/app/toolchains/llvm \
    -DCMAKE_C_COMPILER="/usr/lib/sdk/llvm22/bin/clang" \
    -DCMAKE_CXX_COMPILER="/usr/lib/sdk/llvm22/bin/clang++" \
    -DLLVM_ENABLE_PROJECTS='clang;lld' \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-unknown-linux-gnu \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_PIC=ON \
    -DLLVM_ENABLE_LLD=ON \
    -DLLVM_STATIC_LINK_CXX_STDLIB=ON \
    -DLLVM_ENABLE_UNWIND_TABLES=OFF \
    -DLLVM_ENABLE_ZLIB=FORCE_ON \
    -DLLVM_FORCE_VC_REVISION="$(cat clang-commit)" \
    -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project \
    -DLLVM_INSTALL_UTILS=ON \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_CURL=OFF \
    -DLLVM_ENABLE_Z3_SOLVER=OFF \
    -DLLVM_ENABLE_IO_SANDBOX=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_PLUGIN_SUPPORT=OFF \
    -DLIBCLANG_BUILD_STATIC=ON \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=ON \
    -DCOMPILER_RT_BUILD_XRAY=OFF
cmake --build build --parallel "${FLATPAK_BUILDER_N_JOBS}"
cmake --install build
cp clang-revision /app/toolchains/llvm/cr_build_revision
