#!/usr/bin/env python3
"""Regenerate offline Flatpak toolchain modules for a Chromium release.

Requires Python 3.11+. Reads release metadata and verifies pinned build-tool
archives; flatpak-builder downloads the declared sources for the build.
"""
import argparse
import ast
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import tomllib
from urllib.parse import quote
from urllib.request import urlopen
import zipfile

ROOT = Path(__file__).resolve().parent


def fetch(url):
    with urlopen(url, timeout=60) as response:
        return response.read()


def github(repo, revision, path):
    return fetch(f'https://raw.githubusercontent.com/{repo}/{revision}/{path}')


def constant(source, name):
    for node in ast.parse(source).body:
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == name
            for target in node.targets
        ):
            return ast.literal_eval(node.value)
    raise ValueError(f'Missing upstream constant: {name}')


def gcs_objects(deps, path):
    for node in ast.walk(ast.parse(deps)):
        if isinstance(node, ast.Dict):
            for key, value in zip(node.keys, node.values):
                if isinstance(key, ast.Constant) and key.value == path:
                    for field, objects in zip(value.keys, value.values):
                        if isinstance(field, ast.Constant) and field.value == 'objects':
                            return ast.literal_eval(objects)
    raise ValueError(f'Missing GCS dependency: {path}')


def deps_value(deps, name):
    for node in ast.walk(ast.parse(deps)):
        if isinstance(node, ast.Dict):
            for key, value in zip(node.keys, node.values):
                if isinstance(key, ast.Constant) and key.value == name:
                    return ast.literal_eval(value)
    raise ValueError(f'Missing upstream dependency variable: {name}')


def jdk_binaries(deps):
    packages = None
    for node in ast.walk(ast.parse(deps)):
        if isinstance(node, ast.Dict):
            for key, value in zip(node.keys, node.values):
                if isinstance(key, ast.Constant) and key.value == 'src/third_party/jdk/current':
                    for field, entries in zip(value.keys, value.values):
                        if isinstance(field, ast.Constant) and field.value == 'packages':
                            packages = ast.literal_eval(entries)
    if packages is None or len(packages) != 1:
        raise ValueError('Expected one pinned Chromium JDK package')
    package = packages[0]
    if package['package'] != 'chromium/third_party/jdk/linux-amd64':
        raise ValueError('Unexpected Chromium JDK package')
    url = f'https://chrome-infra-packages.appspot.com/dl/{package["package"]}/+/{package["version"]}'
    binary = fetch(url)
    with zipfile.ZipFile(io.BytesIO(binary)) as archive:
        manifest = json.loads(archive.read('.cipdpkg/manifest.json'))
        if manifest['package_name'] != package['package']:
            raise ValueError('Chromium JDK package identity mismatch')
        release = tomllib.loads(archive.read('release').decode())
        wrapper = archive.read('bin/java').decode()
    if release['IMPLEMENTOR'] != 'Eclipse Adoptium' or release['OS_ARCH'] != 'x86_64':
        raise ValueError('Unexpected Chromium JDK vendor or architecture')
    version = release['SEMANTIC_VERSION']
    match = re.fullmatch(r'(\d+)\.\d+\.\d+(?:\.\d+)?\+(\d+)', version)
    if match is None:
        raise ValueError(f'Unrecognized Temurin version: {version}')
    major = match.group(1)
    tag = quote('jdk-' + version, safe='')
    upstream = json.loads(fetch(
        f'https://api.github.com/repos/adoptium/temurin{major}-binaries/releases/tags/{tag}'
    ))
    filename = f'OpenJDK{major}U-jdk_aarch64_linux_hotspot_{version.replace("+", "_")}.tar.gz'
    asset, = [asset for asset in upstream['assets'] if asset['name'] == filename]
    checksum_asset, = [asset for asset in upstream['assets'] if asset['name'] == filename + '.sha256.txt']
    checksum = fetch(checksum_asset['browser_download_url']).decode().split()[0]
    if not re.fullmatch(r'[0-9a-f]{64}', checksum):
        raise ValueError('Invalid Temurin archive checksum')
    if asset.get('digest') and asset['digest'] != 'sha256:' + checksum:
        raise ValueError('Temurin release digest disagrees with checksum file')
    return [
        {
            'type': 'archive', 'archive-type': 'zip', 'url': url,
            'sha256': hashlib.sha256(binary).hexdigest(), 'strip-components': 0,
            'dest': 'jdk', 'only-arches': ['x86_64'],
        },
        {
            'type': 'archive', 'url': asset['browser_download_url'],
            'sha256': checksum, 'dest': 'jdk', 'only-arches': ['aarch64'],
        },
        inline('jdk-java-wrapper', wrapper),
        inline('jdk-version', version + '\n'),
    ]


def typescript_binaries(deps):
    dependency = deps_value(deps, 'src/third_party/typescript/linux-amd64/src')
    package, = dependency['packages']
    name = 'chromium/third_party/typescript/linux-amd64'
    if package['package'] != name:
        raise ValueError('Unexpected TypeScript package')
    url = f'https://chrome-infra-packages.appspot.com/dl/{name}/+/{package["version"]}'
    binary = fetch(url)
    with zipfile.ZipFile(io.BytesIO(binary)) as archive:
        manifest = json.loads(archive.read('.cipdpkg/manifest.json'))
        if manifest['package_name'] != name or 'lib/tsc' not in archive.namelist():
            raise ValueError('Unexpected TypeScript package layout')
        version = json.loads(archive.read('package.json'))['version']
    if package['version'].rsplit('@', 1)[-1] != version:
        raise ValueError('TypeScript archive disagrees with Chromium\'s expected version')
    arm_url = f'https://registry.npmjs.org/@typescript/typescript-linux-arm64/-/typescript-linux-arm64-{version}.tgz'
    arm_binary = fetch(arm_url)
    with tarfile.open(fileobj=io.BytesIO(arm_binary), mode='r:gz') as archive:
        metadata = json.load(archive.extractfile('package/package.json'))
        if metadata['version'] != version or metadata['name'] != '@typescript/typescript-linux-arm64':
            raise ValueError('Unexpected ARM64 TypeScript package')
        archive.getmember('package/lib/tsc')
    return [
        {
            'type': 'archive', 'archive-type': 'zip', 'url': url,
            'sha256': hashlib.sha256(binary).hexdigest(), 'strip-components': 0,
            'dest': 'typescript',
        },
        {
            'type': 'archive', 'url': arm_url,
            'sha256': hashlib.sha256(arm_binary).hexdigest(),
            'dest': 'typescript-arm64', 'only-arches': ['aarch64'],
        },
    ]


def devtools_binaries(deps):
    revision = deps_value(deps, 'devtools_frontend_revision')
    devtools_deps = github('ChromeDevTools/devtools-frontend', revision, 'DEPS')
    sources = []
    for tool in ('esbuild', 'rollup_libs'):
        package, = deps_value(devtools_deps, 'third_party/' + tool)['packages']
        if package['package'] != f'infra/3pp/tools/{tool}/${{{{platform}}}}':
            raise ValueError(f'Unexpected DevTools package: {tool}')
        for arch, platform in (('x86_64', 'linux-amd64'), ('aarch64', 'linux-arm64')):
            name = package['package'].replace('${{platform}}', platform)
            url = f'https://chrome-infra-packages.appspot.com/dl/{name}/+/{package["version"]}'
            binary = fetch(url)
            expected = 'esbuild' if tool == 'esbuild' else f'rollup.linux-{"x64" if arch == "x86_64" else "arm64"}-gnu.node'
            with zipfile.ZipFile(io.BytesIO(binary)) as archive:
                manifest = json.loads(archive.read('.cipdpkg/manifest.json'))
                if manifest['package_name'] != name or expected not in archive.namelist():
                    raise ValueError(f'Unexpected DevTools archive layout: {name}')
            sources.append({
                'type': 'archive', 'archive-type': 'zip', 'url': url,
                'sha256': hashlib.sha256(binary).hexdigest(), 'strip-components': 0,
                'dest': tool, 'only-arches': [arch],
            })
    return sources


def build_tools(deps, node_update):
    node_objects = gcs_objects(deps, 'src/third_party/node/linux')
    if len(node_objects) != 1:
        raise ValueError('Expected one Chromium Linux Node archive')
    node = node_objects[0]
    node_url = 'https://commondatastorage.googleapis.com/chromium-nodejs/' + node['object_name']
    node_archive = fetch(node_url)
    if hashlib.sha256(node_archive).hexdigest() != node['sha256sum']:
        raise ValueError('Chromium Node archive checksum mismatch')
    with tarfile.open(fileobj=io.BytesIO(node_archive), mode='r:gz') as archive:
        header = archive.extractfile('node-linux-x64/include/node/node_version.h').read().decode()
    node_version = '.'.join(
        re.search(rf'^#define NODE_{part}_VERSION (\d+)$', header, re.M).group(1)
        for part in ('MAJOR', 'MINOR', 'PATCH')
    )
    declared_version = re.search(rb'^NODE_VERSION="(v[0-9.]+)"$', node_update, re.M)
    if declared_version is None or declared_version.group(1).decode() != 'v' + node_version:
        raise ValueError('Node archive disagrees with Chromium\'s expected version')
    arm_filename = f'node-v{node_version}-linux-arm64.tar.xz'
    node_base = f'https://nodejs.org/dist/v{node_version}/'
    checksums = fetch(node_base + 'SHASUMS256.txt').decode().splitlines()
    arm_checksum, = [line.split()[0] for line in checksums if line.split()[1] == arm_filename]
    sources = [
        {
            'type': 'archive', 'archive-type': 'tar-gzip', 'url': node_url,
            'sha256': node['sha256sum'], 'dest': 'node', 'only-arches': ['x86_64'],
        },
        {
            'type': 'archive', 'url': node_base + arm_filename,
            'sha256': arm_checksum, 'dest': 'node', 'only-arches': ['aarch64'],
        },
    ]
    dawn_revision = deps_value(deps, 'dawn_revision')
    dawn_deps = base64.b64decode(fetch(
        f'https://dawn.googlesource.com/dawn/+/{dawn_revision}/DEPS?format=TEXT'
    ))
    go_tag = deps_value(dawn_deps, 'dawn_go_version')
    match = re.fullmatch(r'version:\d+@(\d+\.\d+\.\d+)', go_tag)
    if match is None:
        raise ValueError(f'Unrecognized Dawn Go version: {go_tag}')
    go_version = match.group(1)
    for flatpak_arch, cipd_arch in (('x86_64', 'amd64'), ('aarch64', 'arm64')):
        package = f'infra/3pp/tools/go/linux-{cipd_arch}'
        url = f'https://chrome-infra-packages.appspot.com/dl/{package}/+/{go_tag}'
        binary = fetch(url)
        with zipfile.ZipFile(io.BytesIO(binary)) as archive:
            manifest = json.loads(archive.read('.cipdpkg/manifest.json'))
            if manifest['package_name'] != package or 'bin/go' not in archive.namelist():
                raise ValueError(f'Unexpected Go package layout: {package}')
        sources.append({
            'type': 'archive', 'archive-type': 'zip', 'url': url,
            'sha256': hashlib.sha256(binary).hexdigest(), 'strip-components': 0,
            'dest': 'go', 'only-arches': [flatpak_arch],
        })
    sources.extend([
        inline('node-version', 'v' + node_version + '\n'),
        inline('go-version', 'go' + go_version + '\n'),
    ])
    sources.extend(jdk_binaries(deps))
    sources.extend(typescript_binaries(deps))
    sources.extend(devtools_binaries(deps))
    formatter, = gcs_objects(deps, 'src/buildtools/linux64-format')
    sources.append({
        'type': 'file',
        'url': 'https://commondatastorage.googleapis.com/chromium-clang-format/' + formatter['object_name'],
        'sha256': formatter['sha256sum'], 'dest-filename': 'clang-format',
        'only-arches': ['x86_64'],
    })
    return {
        'name': 'chromium-build-tools', 'only-arches': ['x86_64', 'aarch64'],
        'buildsystem': 'simple', 'build-commands': [
            'mkdir -p /app/toolchains',
            'if [ "$FLATPAK_ARCH" = x86_64 ]; then install -Dm755 clang-format /app/toolchains/clang-format; else ln -s llvm/bin/clang-format /app/toolchains/clang-format; fi',
            'if [ "$FLATPAK_ARCH" = aarch64 ]; then mv jdk/bin/java jdk/bin/java.chromium; install -m755 jdk-java-wrapper jdk/bin/java; fi',
            # Keep Chromium's patched declarations; replace only the native compiler.
            'if [ "$FLATPAK_ARCH" = aarch64 ]; then install -m755 typescript-arm64/lib/tsc typescript/lib/tsc; fi',
            'cp -a node go jdk typescript esbuild rollup_libs node-version go-version jdk-version /app/toolchains/',
            # CIPD archives contain read-only binaries; eu-strip needs write access.
            'chmod -R u+w /app/toolchains/node /app/toolchains/go /app/toolchains/jdk /app/toolchains/typescript /app/toolchains/esbuild /app/toolchains/rollup_libs',
        ], 'cleanup': ['/toolchains'], 'sources': sources,
    }


def file_source(path):
    # Included modules resolve local sources relative to toolchains/.
    return {'type': 'file', 'path': '../' + path}


def inline(filename, contents):
    return {'type': 'inline', 'dest-filename': filename, 'contents': contents}


def github_archive(repo, commit, dest):
    url = f'https://codeload.github.com/{repo}/tar.gz/{commit}'
    return {
        'type': 'archive', 'archive-type': 'tar-gzip', 'url': url,
        'sha256': hashlib.sha256(fetch(url)).hexdigest(), 'dest': dest,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version', help='Chromium version, without the UC package release')
    args = parser.parse_args()
    clang_update = github('chromium/chromium', args.version, 'tools/clang/scripts/update.py')
    clang_build = github('chromium/chromium', args.version, 'tools/clang/scripts/build.py')
    rust_update = github('chromium/chromium', args.version, 'tools/rust/update_rust.py')
    rust_build = github('chromium/chromium', args.version, 'tools/rust/build_rust.py')
    bindgen_build = github('chromium/chromium', args.version, 'tools/rust/build_bindgen.py')
    deps = github('chromium/chromium', args.version, 'DEPS')
    node_update = github('chromium/chromium', args.version, 'third_party/node/update_node_binaries')
    tools = build_tools(deps, node_update)
    clang_revision = constant(clang_update, 'CLANG_REVISION')
    clang_package = f'{clang_revision}-{constant(clang_update, "CLANG_SUB_REVISION")}'
    rust_revision = constant(rust_update, 'RUST_REVISION')
    rust_package = f'{rust_revision}-{constant(rust_update, "RUST_SUB_REVISION")}-{clang_revision}'
    bindgen_revision = constant(bindgen_build, 'BINDGEN_GIT_VERSION')

    # Use upstream's SHA256s, rather than trusting an unchecked hook download.
    binary_sources = []
    for path, filename, dest in (
        ('src/third_party/llvm-build/Release+Asserts', f'Linux_x64/clang-{clang_package}.tar.xz', 'llvm'),
        ('src/third_party/llvm-build/Release+Asserts', f'Linux_x64/llvmobjdump-{clang_package}.tar.xz', 'llvm'),
        ('src/third_party/rust-toolchain', f'Linux_x64/rust-toolchain-{rust_package}.tar.xz', 'rust'),
        ('src/third_party/llvm-libclang', f'Linux_x64/rust-libclang-{rust_package}.tar.xz', 'libclang'),
    ):
        matches = [obj for obj in gcs_objects(deps, path) if obj['object_name'] == filename]
        if len(matches) != 1:
            raise ValueError(f'Expected one upstream archive for {filename}')
        obj = matches[0]
        binary_sources.append({
            'type': 'archive',
            'url': 'https://commondatastorage.googleapis.com/chromium-browser-clang/' + obj['object_name'],
            'sha256': obj['sha256sum'], 'dest': dest, 'strip-components': 0,
        })
    prebuilt = {
        'name': 'google-toolchains', 'only-arches': ['x86_64'],
        'buildsystem': 'simple', 'build-commands': [
            'mkdir -p /app/toolchains',
            'cp -a llvm rust libclang /app/toolchains/',
            f'printf "%s\\n" "{clang_package}" > /app/toolchains/llvm/cr_build_revision',
        ], 'cleanup': ['/toolchains'], 'sources': binary_sources,
    }

    # Chromium's LLVM revision is a git-describe string, not an upstream tag.
    llvm_short = clang_revision.rsplit('-g', 1)[1]
    llvm_commit = json.loads(fetch(
        f'https://api.github.com/repos/llvm/llvm-project/commits/{llvm_short}'
    ))['sha']
    llvm_sources = [github_archive('llvm/llvm-project', llvm_commit, 'llvm')]
    llvm_patches = set()
    # Match the downstream fixes applied by Chromium's own build.py.
    for revision in re.findall(rb"GitCherryPick\(LLVM_DIR, '([0-9a-f]+)'\)", clang_build):
        revision = revision.decode()
        patch = fetch(f'https://github.com/llvm/llvm-project/commit/{revision}.patch')
        filename = f'llvm-{revision}.patch'
        (ROOT / filename).write_bytes(patch)
        llvm_patches.add(filename)
        llvm_sources.append({'type': 'patch', 'path': filename, 'options': ['-d', 'llvm']})
    llvm_sources.extend([
        file_source('build-steps/llvm/0010-build.sh'),
        inline('clang-revision', clang_package + '\n'),
    ])
    llvm = {
        'name': 'native-llvm', 'only-arches': ['aarch64'],
        'buildsystem': 'simple', 'build-commands': ['bash 0010-build.sh'],
        'cleanup': ['/toolchains'], 'sources': llvm_sources,
    }

    rust_tree = json.loads(fetch(
        f'https://api.github.com/repos/rust-lang/rust/git/trees/{rust_revision}'
    ))
    library = next(item['sha'] for item in rust_tree['tree'] if item['path'] == 'library')
    library_tree = json.loads(fetch(
        f'https://api.github.com/repos/rust-lang/rust/git/trees/{library}'
    ))
    backtrace = next(item['sha'] for item in library_tree['tree'] if item['path'] == 'backtrace')
    stage0 = dict(
        line.split('=', 1) for line in
        github('rust-lang/rust', rust_revision, 'src/stage0').decode().splitlines()
        if line and not line.startswith('#')
    )
    sources = [
        github_archive('rust-lang/rust', rust_revision, 'rust'),
        github_archive('rust-lang/backtrace-rs', backtrace, 'rust/library/backtrace'),
        github_archive('rust-lang/rust-bindgen', bindgen_revision, 'bindgen'),
    ]
    rust_patches = set()
    # The revision alone does not include Google's downstream Rust fixes.
    for revision in re.findall(rb"GitCherryPick\(RUST_SRC_DIR, '([0-9a-f]+)'", rust_build):
        revision = revision.decode()
        filename = f'rust-{revision}.patch'
        comparison = json.loads(fetch(
            f'https://api.github.com/repos/rust-lang/rust/compare/{revision}...{rust_revision}'
        ))
        if comparison['status'] in ('ahead', 'identical'):
            continue
        patch = fetch(
            f'https://github.com/rust-lang/rust/commit/{revision}.patch'
        )
        # Chromium's list can retain already-landed fixes (including rebased
        # commits). Check the actual pinned files, not just commit ancestry.
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            for path in re.findall(rb'^--- a/(.+)$', patch, re.M):
                path = path.decode()
                target = checkout / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(github('rust-lang/rust', rust_revision, path))
            applied = subprocess.run(
                ['git', 'apply', '--reverse', '--check', '-'], input=patch,
                cwd=checkout, capture_output=True,
            )
            if applied.returncode == 0:
                continue
            subprocess.run(
                ['git', 'apply', '--check', '-'], input=patch,
                cwd=checkout, check=True,
            )
        (ROOT / filename).write_bytes(patch)
        rust_patches.add(filename)
        sources.append({'type': 'patch', 'path': filename, 'options': ['-d', 'rust']})
    # Scope copyright metadata to the workspaces used by our offline build.
    sources.append({
        'type': 'patch', 'path': 'offline-rust-copyright.patch',
        'options': ['-d', 'rust'],
    })
    # External llvm-config does not supply sources for optimized builtins or
    # profiler support. Reuse Chromium's pinned, patched LLVM source tree.
    for source in llvm_sources:
        if source['type'] == 'archive':
            sources.append({**source, 'dest': 'rust/src/llvm-project'})
        elif source['type'] == 'patch':
            sources.append({**source, 'options': ['-d', 'rust/src/llvm-project']})
    # Rust bootstrap reads this metadata when building from a source tarball.
    rust_commit = json.loads(fetch(
        f'https://api.github.com/repos/rust-lang/rust/commits/{rust_revision}'
    ))
    commit_date = rust_commit['commit']['committer']['date'].split('T', 1)[0]
    sources.extend([
        {**inline('git-commit-info', f'{rust_revision}\n{rust_revision[:9]}\n{commit_date}\n'), 'dest': 'rust'},
        {**inline('git-commit-hash', rust_revision + '\n'), 'dest': 'rust'},
    ])
    for component in ('rustc', 'cargo', 'rust-std'):
        archive = f'dist/{stage0["compiler_date"]}/{component}-{stage0["compiler_version"]}-aarch64-unknown-linux-gnu.tar.xz'
        sources.append({
            'type': 'archive', 'url': stage0['dist_server'] + '/' + archive,
            'sha256': stage0[archive], 'dest': f'bootstrap-{component}',
        })

    # Compiler, bootstrap, stdlib and bindgen are separate Cargo workspaces.
    crates = {}
    coordinates = {}
    for repo, revision, lock in (
        ('rust-lang/rust', rust_revision, 'Cargo.lock'),
        ('rust-lang/rust', rust_revision, 'src/bootstrap/Cargo.lock'),
        ('rust-lang/rust', rust_revision, 'library/Cargo.lock'),
        ('rust-lang/rust-bindgen', bindgen_revision, 'Cargo.lock'),
    ):
        for package in tomllib.loads(github(repo, revision, lock).decode())['package']:
            if 'source' not in package:
                continue
            if package['source'] != 'registry+https://github.com/rust-lang/crates.io-index':
                raise ValueError(f'Unreviewed Cargo source: {package["source"]}')
            directory = f'{package["name"]}-{package["version"]}'
            checksum = package['checksum']
            if directory in crates and crates[directory] != checksum:
                raise ValueError(f'Conflicting checksum: {directory}')
            crates[directory] = checksum
            coordinates[directory] = (package['name'], package['version'])
    for directory, checksum in sorted(crates.items()):
        name, version = coordinates[directory]
        sources.append({
            'type': 'archive', 'archive-type': 'tar-gzip',
            'url': f'https://static.crates.io/crates/{name}/{name}-{version}.crate',
            'sha256': checksum, 'dest': f'vendor/{directory}',
        })
    sources.extend([
        file_source('build-steps/rust/0010-install-bootstrap.sh'),
        file_source('build-steps/rust/0020-prepare-vendor.py'),
        file_source('build-steps/rust/0030-build.sh'),
        inline('crate-checksums.json', json.dumps(crates, sort_keys=True) + '\n'),
        inline('rust-revision', rust_package + '\n'),
        inline('rust-commit', rust_revision + '\n'),
    ])
    rust = {
        'name': 'native-rust', 'only-arches': ['aarch64'],
        'buildsystem': 'simple', 'build-commands': [
            'bash 0010-install-bootstrap.sh',
            'python3 0020-prepare-vendor.py',
            'bash 0030-build.sh',
        ],
        'cleanup': ['/toolchains'], 'sources': sources,
    }
    for filename, module in (
        ('google.json', prebuilt), ('llvm.json', llvm), ('rust.json', rust),
        ('build-tools.json', tools),
    ):
        (ROOT / filename).write_text(json.dumps(module, indent=2) + '\n')
    # Remove patches from earlier releases only after writing the new manifests.
    for patch in ROOT.glob('llvm-*.patch'):
        if patch.name not in llvm_patches:
            patch.unlink()
    for patch in ROOT.glob('rust-*.patch'):
        if patch.name not in rust_patches:
            patch.unlink()
    print(f'Pinned {clang_package}, {rust_package}, and {len(crates)} offline crates')


if __name__ == '__main__':
    main()
