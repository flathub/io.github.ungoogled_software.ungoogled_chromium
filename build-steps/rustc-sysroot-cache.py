#!/usr/bin/env python3
"""Cache Rust builds with explicit sysroots, including Rust's bootstrap stages."""
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

SCCACHE = '/app/bin/sccache'


def expand_arguments(arguments):
    result = []
    for arg in arguments:
        if arg.startswith('@'):
            result.extend(expand_arguments([
                line.strip() for line in Path(arg[1:]).read_text().splitlines() if line.strip()]))
        else:
            result.append(arg)
    return result


def file_digest(path, memo):
    # Memoize content hashes only while the file's identity and change timestamps
    # match. Re-extracting or replacing a toolchain invalidates these entries.
    stat = path.stat()
    identity = (str(path.resolve()), stat.st_dev, stat.st_ino, stat.st_size,
                stat.st_mtime_ns, stat.st_ctime_ns)
    key = hashlib.sha256(repr(identity).encode()).hexdigest()
    entry = memo / key
    if entry.exists():
        return entry.read_text()
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    value = digest.hexdigest()
    # Atomic publication allows simultaneous Cargo/Ninja invocations.
    with tempfile.NamedTemporaryFile(mode='w', dir=memo, delete=False) as stream:
        stream.write(value)
    os.replace(stream.name, entry)
    return value


def tree_digest(root, memo):
    digest = hashlib.sha256()
    visited = set()
    for directory, dirs, files in os.walk(root, followlinks=True):
        # Follow library directory symlinks, but never revisit a directory:
        # bootstrap sysroots may contain links back into the build tree.
        stat = Path(directory).stat()
        identity = (stat.st_dev, stat.st_ino)
        if identity in visited:
            dirs.clear()
            continue
        visited.add(identity)
        # Source files are tracked by rustc/sccache, not implicit binary deps.
        # rustc-src points to the source tree, which contains this sysroot.
        dirs[:] = sorted(name for name in dirs if name not in ('src', 'rustc-src'))
        for name in sorted(files):
            path = Path(directory) / name
            if path.is_file():
                digest.update(str(path.relative_to(root)).encode() + b'\0')
                digest.update(file_digest(path, memo).encode())
    return digest.hexdigest()


def prepare(compiler, arguments, scratch):
    if Path(compiler).name not in ('rustc', 'clippy-driver'):
        return compiler, arguments, dict(os.environ)
    arguments = expand_arguments(arguments)
    filtered = []
    sysroot = None
    iterator = iter(arguments)
    for arg in iterator:
        if arg == '--sysroot':
            sysroot = next(iterator)
        elif arg.startswith('--sysroot='):
            sysroot = arg.partition('=')[2]
        else:
            filtered.append(arg)
    if sysroot is None:
        return compiler, arguments, dict(os.environ)

    compiler = Path(shutil.which(compiler) or compiler).resolve()
    sysroot = Path(sysroot).resolve()
    if not (sysroot / 'lib').is_dir():
        # Let rustc diagnose malformed sysroots using its original arguments.
        return str(compiler), arguments, dict(os.environ)
    memo = scratch / 'digests'
    memo.mkdir(parents=True, exist_ok=True)
    # This metadata probe needs no jobserver tokens. subprocess closes inherited
    # pipe descriptors, so do not advertise them to the probe via its environment.
    probe_env = dict(os.environ)
    for name in ('CARGO_MAKEFLAGS', 'MAKEFLAGS', 'MFLAGS'):
        probe_env.pop(name, None)
    compiler_root = Path(subprocess.check_output(
        [str(compiler), '--print=sysroot'], text=True, env=probe_env).strip())
    compiler_hash = hashlib.sha256(file_digest(compiler, memo).encode())
    for path in sorted((compiler_root / 'lib').glob('*')):
        if path.is_file():
            compiler_hash.update(file_digest(path, memo).encode())
    key = hashlib.sha256((str(compiler) + '\0' + str(sysroot) + '\0'
                          + compiler_hash.hexdigest()).encode()).hexdigest()
    directory = scratch / key
    directory.mkdir(parents=True, exist_ok=True)
    wrapper = directory / 'rustc'
    if not wrapper.exists():
        # sccache needs the compiler's own shared libraries for its compiler
        # fingerprint. Compilation still uses exactly the requested sysroot.
        script = ('#!/bin/sh\n'
                  'if [ "$#" = 1 ] && [ "$1" = --print=sysroot ]; then\n'
                  f'  exec {shlex.quote(str(compiler))} "$@"\nfi\n'
                  f'exec {shlex.quote(str(compiler))} '
                  f'--sysroot={shlex.quote(str(sysroot))} "$@"\n')
        with tempfile.NamedTemporaryFile(mode='w', dir=directory, delete=False) as stream:
            stream.write(script)
        os.chmod(stream.name, 0o755)
        os.replace(stream.name, wrapper)
    env = dict(os.environ)
    # sccache hashes CARGO_* variables. Include the selected sysroot's content,
    # since its implicit libraries aren't ordinary --extern dependencies.
    env['CARGO_SCCACHE_SYSROOT'] = str(sysroot)
    env['CARGO_SCCACHE_SYSROOT_DIGEST'] = tree_digest(sysroot / 'lib', memo)
    env['CARGO_SCCACHE_COMPILER_DIGEST'] = compiler_hash.hexdigest()
    return str(wrapper), filtered, env


def main():
    compiler, *arguments = sys.argv[1:]
    scratch = Path(tempfile.gettempdir()) / 'flatpak-rustc-cache'
    compiler, arguments, env = prepare(compiler, arguments, scratch)
    # Replace the wrapper so Cargo's inherited jobserver pipe stays open, with
    # its environment intact. A subprocess would close the pipe by default.
    os.execvpe(SCCACHE, [SCCACHE, compiler, *arguments], env)


if __name__ == '__main__':
    sys.exit(main())
