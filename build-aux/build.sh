#!/bin/bash -ex

ln_overwrite_all() {
	rm -rf "${2}"
	ln -s "${1}" "${2}"
}

# Link our verisons of Node and OpenJDK into Chromium so the build scripts will
# use them. For OpenJDK especially, this is a workaround for:
# https://bugs.chromium.org/p/chromium/issues/detail?id=1192875
ln_overwrite_all /usr/lib/sdk/node20 third_party/node/linux/node-linux-x64
ln_overwrite_all /usr/lib/sdk/openjdk21 third_party/jdk/current

# Use system clang
. /usr/lib/sdk/llvm19/enable.sh
export CC=clang
export CXX=clang++
export AR=ar
export NM=nm

# Allow the use of nightly features with stable Rust compiler
# https://github.com/ungoogled-software/ungoogled-chromium/pull/2696#issuecomment-1918173198
export RUSTC_BOOTSTRAP=1

# Facilitate deterministic builds (taken from build/config/compiler/BUILD.gn)
CFLAGS+='   -Wno-builtin-macro-redefined'
CXXFLAGS+=' -Wno-builtin-macro-redefined'
CPPFLAGS+=' -D__DATE__=  -D__TIME__=  -D__TIMESTAMP__='

# Do not warn about unknown warning options
CFLAGS+='   -Wno-unknown-warning-option'
CXXFLAGS+=' -Wno-unknown-warning-option'

# Let Chromium set its own symbol level
CFLAGS=${CFLAGS/-g }
CXXFLAGS=${CXXFLAGS/-g }

# https://github.com/ungoogled-software/ungoogled-chromium-archlinux/issues/123
CFLAGS=${CFLAGS/-fexceptions}
CFLAGS=${CFLAGS/-fcf-protection}
CXXFLAGS=${CXXFLAGS/-fexceptions}
CXXFLAGS=${CXXFLAGS/-fcf-protection}

# This appears to cause random segfaults when combined with ThinLTO
# https://bugs.archlinux.org/task/73518
CFLAGS=${CFLAGS/-fstack-clash-protection}
CXXFLAGS=${CXXFLAGS/-fstack-clash-protection}

# https://crbug.com/957519#c122
CXXFLAGS=${CXXFLAGS/-Wp,-D_GLIBCXX_ASSERTIONS}

# Configure and build Chromium
out/Release/gn gen out/Release
ninja -C out/Release -j"${FLATPAK_BUILDER_N_JOBS}" chrome chrome_crashpad_handler
