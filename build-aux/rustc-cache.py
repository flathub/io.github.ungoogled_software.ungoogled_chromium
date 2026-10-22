#!/usr/bin/env python3
"""Adapt Chromium's Linux Rust library outputs to sccache's Cargo-style interface."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import tempfile


SCCACHE = '/app/bin/sccache'
STAGING_SUFFIX = '.sccache'
TEMP_PREFIX = '.rustc-cache-'


def expand_response_files(arguments):
    result = []
    for argument in arguments:
        if argument.startswith('@'):
            result.extend(expand_response_files(Path(argument[1:]).read_text().splitlines()))
        else:
            result.append(argument)
    return result


def cache_command(arguments):
    """Return cacheable arguments and output mappings, or None for link steps."""
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument('--crate-name')
    parser.add_argument('--crate-type')
    parser.add_argument('--emit')
    parser.add_argument('-o')
    parser.add_argument('-C', action='append', default=[])
    options, _ = parser.parse_known_args(arguments)
    if (options.crate_type not in ('rlib', 'staticlib') or not options.o
            or not options.crate_name or not options.emit):
        return None
    if not re.fullmatch(r'[A-Za-z0-9_]+', options.crate_name):
        return None
    emits = dict(part.partition('=')[::2] for part in options.emit.split(','))
    if not {'link', 'dep-info'} <= emits.keys() or emits.keys() - {'link', 'dep-info', 'metadata'}:
        return None
    if not emits['dep-info'] or ('metadata' in emits and not emits['metadata']):
        return None
    if emits['link'] or (options.crate_type == 'staticlib' and 'metadata' in emits):
        return None
    extra = ''
    for option in options.C:
        if option.startswith('incremental='):
            return None
        if option.startswith('extra-filename='):
            extra = option.partition('=')[2]
    if '/' in extra or '\\' in extra:
        return None

    # A stable, per-output directory avoids collisions between crates with the
    # same name and permits reuse after flatpak-builder recreates the source tree.
    output = Path(options.o)
    directory = output.parent / (output.name + STAGING_SUFFIX)
    stem = options.crate_name + extra
    suffix = '.rlib' if options.crate_type == 'rlib' else '.a'
    outputs = {directory / ('lib' + stem + suffix): output,
               directory / (stem + '.d'): Path(emits['dep-info'])}
    if 'metadata' in emits:
        outputs[directory / ('lib' + stem + '.rmeta')] = Path(emits['metadata'])

    # Retain every compiler option except the output paths being translated.
    translated = []
    arguments = iter(arguments)
    for argument in arguments:
        if argument in ('-o', '--emit'):
            next(arguments)
        elif argument.startswith('--emit=') or (argument.startswith('-o') and argument != '-o'):
            continue
        else:
            translated.append(argument)
    translated += ['--out-dir', str(directory), '--emit', ','.join(emits)]
    return translated, outputs, Path(emits['dep-info'])


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


def is_transient(name):
    # Staging directories and temporary files of concurrent wrapper invocations
    # appear and disappear while the sysroot is being populated. Chromium builds
    # its own stdlib into local_rustc_sysroot, so sibling jobs share this tree.
    return name.endswith(STAGING_SUFFIX) or name.startswith(TEMP_PREFIX)


def tree_digest(root, memo):
    digest = hashlib.sha256()
    visited = set()
    for directory, dirs, files in os.walk(root, followlinks=True):
        # Follow library directory symlinks, but never revisit a directory:
        # Chromium sysroots may contain links back into the build tree.
        try:
            stat = Path(directory).stat()
        except FileNotFoundError:
            dirs.clear()
            continue
        identity = (stat.st_dev, stat.st_ino)
        if identity in visited:
            dirs.clear()
            continue
        visited.add(identity)
        # Source files are tracked by rustc/sccache, not implicit binary deps.
        # rustc-src points to the source tree, which contains this sysroot.
        dirs[:] = sorted(name for name in dirs
                         if name not in ('src', 'rustc-src') and not is_transient(name))
        for name in sorted(files):
            if is_transient(name):
                continue
            path = Path(directory) / name
            try:
                if not path.is_file():
                    continue
                entry = file_digest(path, memo)
            except FileNotFoundError:
                # Removed by a concurrent job between listing and hashing.
                continue
            digest.update(str(path.relative_to(root)).encode() + b'\0')
            digest.update(entry.encode())
    return digest.hexdigest()


def prepare(compiler, arguments, scratch):
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
    compiler, *original = sys.argv[1:]
    arguments = expand_response_files(original)
    command = cache_command(arguments)
    if command is None:
        # Uncacheable invocations use sccache directly for fallback and statistics.
        return subprocess.call([SCCACHE, compiler, *original])
    translated, outputs, depfile = command
    directory = next(iter(outputs)).parent
    directory.mkdir(parents=True, exist_ok=True)
    # Chromium uses explicit stdlib sysroots even with prebuilt compilers.
    # Include their contents in the cache key while adapting --sysroot.
    scratch = Path(tempfile.gettempdir()) / 'flatpak-rustc-cache'
    compiler, translated, env = prepare(compiler, translated, scratch)
    status = subprocess.call([SCCACHE, compiler, *translated], env=env)
    if status:
        return status
    for source, destination in outputs.items():
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Publish atomically: concurrent jobs digest this directory and must
        # never observe a partially written library.
        with tempfile.NamedTemporaryFile(prefix=TEMP_PREFIX, dir=destination.parent,
                                         delete=False) as stream:
            pass
        shutil.copy(source, stream.name)
        os.replace(stream.name, destination)
    # rustc names the translated outputs in its Make depfile. Restore Ninja's
    # declared targets before Chromium normalizes/validates the dependencies.
    dependency_text = depfile.read_text()
    for source, destination in outputs.items():
        source_target = str(source).replace(' ', '\\ ') + ':'
        destination_target = str(destination).replace(' ', '\\ ') + ':'
        dependency_text = ''.join(
            destination_target + line[len(source_target):]
            if line.startswith(source_target) else line
            for line in dependency_text.splitlines(keepends=True))
    depfile.write_text(dependency_text)
    shutil.rmtree(directory)
    return 0


if __name__ == '__main__':
    sys.exit(main())
