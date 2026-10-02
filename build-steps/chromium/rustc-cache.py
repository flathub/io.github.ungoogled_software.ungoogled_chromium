#!/usr/bin/env python3
"""Adapt Chromium's Linux Rust library outputs to sccache's Cargo-style interface."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys


SCCACHE = '/app/libexec/sccache'


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
    directory = output.parent / (output.name + '.sccache')
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


def main():
    compiler, *original = sys.argv[1:]
    arguments = expand_response_files(original)
    command = cache_command(arguments)
    if command is None:
        # sccache still reports why invocations such as binaries/proc macros
        # cannot be cached, and runs the actual compiler for them.
        return subprocess.call([SCCACHE, compiler, *original])
    translated, outputs, depfile = command
    directory = next(iter(outputs)).parent
    directory.mkdir(parents=True, exist_ok=True)
    status = subprocess.call([SCCACHE, compiler, *translated])
    if status:
        return status
    for source, destination in outputs.items():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
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
