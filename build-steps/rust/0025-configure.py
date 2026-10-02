#!/usr/bin/env python3
"""Adapt Chromium's Rust template for an offline native ARM64 build."""
import json
from pathlib import Path
import re
from string import Template
import tomllib


def configure(template, build_dir, package):
    config = Template(template).substitute(
        CHANGELOG_SEEN='change-id = "ignore"',
        INSTALL_DIR='/app/toolchains/rust',
        LLVM_BIN='/app/toolchains/llvm/bin',
        PACKAGE_VERSION=package,
    )
    # Keep Google's compiler settings, including jemalloc. Only install tools
    # needed by Chromium. Reuse the prebuilt stage0 Cargo for bindgen and Crubit.
    config, count = re.subn(r'(?m)^tools = \[.*?^\]',
                           'tools = ["rustc-dev", "rustfmt", "src"]',
                           config, flags=re.S)
    if count != 1:
        raise ValueError('Unexpected upstream Rust tools configuration')
    config = config.replace('[target.x86_64-unknown-linux-gnu]',
                            '[target.aarch64-unknown-linux-gnu]')
    additions = '\n'.join([
        'build = "aarch64-unknown-linux-gnu"',
        'host = ["aarch64-unknown-linux-gnu"]',
        'target = ["aarch64-unknown-linux-gnu"]',
        'rustc = ' + json.dumps(str(build_dir / 'bootstrap/bin/rustc')),
        'cargo = ' + json.dumps(str(build_dir / 'bootstrap/bin/cargo')),
        'vendor = true',
        'ccache = "sccache"',
        'submodules = false',
    ])
    config = config.replace('[build]\n', '[build]\n' + additions + '\n', 1)
    # Detect duplicate keys or upstream format changes before invoking x.py.
    parsed = tomllib.loads(config)
    if (parsed['target']['aarch64-unknown-linux-gnu']['jemalloc'] is not True
            or parsed['build']['vendor'] is not True):
        raise ValueError('Unexpected native Rust configuration')
    return config


def main():
    root = Path.cwd()
    (root / 'rust/bootstrap.toml').write_text(configure(
        (root / 'config.toml.template').read_text(), root,
        (root / 'rust-revision').read_text().strip()))
    # Match build_rust.py's workaround for rust-lang/cargo#14253.
    manifest = root / 'rust/src/bootstrap/Cargo.toml'
    manifest.write_text(''.join(line for line in manifest.read_text().splitlines(keepends=True)
                               if line.rstrip('\n') != 'debug = 0'))


if __name__ == '__main__':
    main()
