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
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tempfile
import tomllib
from urllib.parse import quote
from urllib.error import HTTPError
from urllib.request import urlopen
import zipfile

ROOT = Path(__file__).resolve().parent
# Infrastructure revision supplying the gperf source-build recipe.
GPERF_INFRA_REVISION = '15fb2e2eae990f900bd8f3c0e9b4612cd0b407bf'
UPSTREAM_RECIPES = (
    'tools/clang/scripts/update.py',
    'tools/clang/scripts/build.py',
    'tools/rust/update_rust.py',
    'tools/rust/build_rust.py',
    'tools/rust/build_bindgen.py',
    'tools/rust/config.toml.template',
    'third_party/node/update_node_binaries',
)


def cherry_picks(source, directory, repo):
    """Read supported cherry-pick calls from the upstream build recipe."""
    revisions = []
    calls = sorted((node for node in ast.walk(ast.parse(source))
                    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)),
                   key=lambda node: (node.lineno, node.col_offset))
    for call in calls:
        if call.func.id in ('GitRevert', 'GitMoveSubmoduleBranch'):
            raise ValueError(f'Unimplemented upstream source operation: {call.func.id}')
        if call.func.id != 'GitCherryPick':
            continue
        if (not 2 <= len(call.args) <= 3 or call.keywords
                or not isinstance(call.args[0], ast.Name)
                or call.args[0].id != directory):
            raise ValueError('Unrecognized upstream GitCherryPick call')
        revision = ast.literal_eval(call.args[1])
        if not isinstance(revision, str) or not re.fullmatch(r'[0-9a-f]{40}', revision):
            raise ValueError('Expected a full cherry-pick commit')
        if len(call.args) == 3 and ast.literal_eval(call.args[2]) != f'https://github.com/{repo}.git':
            raise ValueError('Unexpected cherry-pick repository')
        revisions.append(revision)
    return revisions


def submodule(repo, revision, path, expected_repo):
    metadata = json.loads(fetch(f'https://api.github.com/repos/{repo}/contents/{path}?ref={revision}'))
    if (metadata.get('submodule_git_url') != f'https://github.com/{expected_repo}.git'
            or not re.fullmatch(r'[0-9a-f]{40}', metadata['sha'])):
        raise ValueError(f'Unexpected submodule: {path}')
    return metadata['sha']


def verified_stage0(source, rust_update):
    if hashlib.sha256(source).hexdigest() != constant(rust_update, 'STAGE0_JSON_SHA256'):
        raise ValueError("Rust src/stage0 disagrees with Chromium's expected hash")
    return dict(line.split('=', 1) for line in source.decode().splitlines()
                if line and not line.startswith('#'))


def prepare_patches(repo, base, revisions, prefix, dest):
    """Replay text patches in order, retaining edited lockfiles for vendoring."""
    patches, sources, files = {}, [], {}
    with tempfile.TemporaryDirectory() as directory:
        checkout = Path(directory)
        loaded = set()
        for revision in revisions:
            comparison = json.loads(fetch(
                f'https://api.github.com/repos/{repo}/compare/{revision}...{base}'))
            if comparison['status'] in ('ahead', 'identical'):
                continue
            patch = fetch(f'https://github.com/{repo}/commit/{revision}.patch')
            old_paths = set(re.findall(rb'^--- a/(.+)$', patch, re.M))
            new_paths = set(re.findall(rb'^\+\+\+ b/(.+)$', patch, re.M))
            if not (old_paths | new_paths) or b'GIT binary patch' in patch:
                raise ValueError(f'Unsupported source patch: {revision}')
            for raw in old_paths | new_paths:
                path = raw.decode()
                if PurePosixPath(path).is_absolute() or '..' in PurePosixPath(path).parts:
                    raise ValueError(f'Unsafe patch path: {path}')
                target = checkout / path
                if path not in loaded:
                    loaded.add(path)
                    try:
                        contents = github(repo, base, path)
                    except HTTPError as error:
                        if error.code != 404 or raw in old_paths:
                            raise
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(contents)
            # Rebased fixes can already be present without commit ancestry.
            if subprocess.run(['git', 'apply', '--reverse', '--check', '-'],
                              input=patch, cwd=checkout, capture_output=True).returncode == 0:
                continue
            subprocess.run(['git', 'apply', '--check', '-'], input=patch, cwd=checkout, check=True)
            subprocess.run(['git', 'apply', '-'], input=patch, cwd=checkout, check=True)
            filename = f'{prefix}-{revision}.patch'
            patches[filename] = patch
            sources.append({'type': 'patch', 'path': filename, 'options': ['-d', dest]})
        for path in loaded:
            target = checkout / path
            files[path] = target.read_bytes() if target.exists() else None
    return patches, sources, files


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
        google_compiler = archive.read('lib/tsc')
    if package['version'].rsplit('@', 1)[-1] != version:
        raise ValueError('TypeScript archive disagrees with Chromium\'s expected version')
    # Prove that replacing the executable preserves the vendor compiler choice:
    # Google's x64 executable must be exactly npm's corresponding executable.
    x64_url = f'https://registry.npmjs.org/@typescript/typescript-linux-x64/-/typescript-linux-x64-{version}.tgz'
    with tarfile.open(fileobj=io.BytesIO(fetch(x64_url)), mode='r:gz') as archive:
        if archive.extractfile('package/lib/tsc').read() != google_compiler:
            raise ValueError('Chromium patches the TypeScript executable; review the ARM64 substitution')
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


def gperf_sources(deps):
    package, = deps_value(deps, 'src/third_party/gperf/cipd')['packages']
    if package['package'] != 'infra/3pp/tools/gperf/${{platform}}':
        raise ValueError('Unexpected gperf package')
    name = 'infra/3pp/tools/gperf/linux-amd64'
    url = f'https://chrome-infra-packages.appspot.com/dl/{name}/+/{package["version"]}'
    binary = fetch(url)
    with zipfile.ZipFile(io.BytesIO(binary)) as archive:
        if (json.loads(archive.read('.cipdpkg/manifest.json'))['package_name'] != name
                or 'bin/gperf' not in archive.namelist()):
            raise ValueError(f'Unexpected gperf package: {name}')
    sources = [{
        'type': 'archive', 'archive-type': 'zip', 'url': url,
        'sha256': hashlib.sha256(binary).hexdigest(), 'strip-components': 0,
        'dest': 'gperf', 'only-arches': ['x86_64'],
    }]
    recipes = {}
    for path in ('3pp/gperf/3pp.pb', '3pp/gperf/install.sh', '3pp/gperf/README.chromium'):
        recipe = base64.b64decode(fetch(
            'https://chromium.googlesource.com/infra/infra/+/'
            + GPERF_INFRA_REVISION + '/' + path + '?format=TEXT'))
        recipes[path] = recipe.decode()
    specification = recipes['3pp/gperf/3pp.pb']
    source_url, = re.findall(r'download_url: "([^"]+)"', specification)
    version, = re.findall(r'(?m)^      version: "([^"]+)"', specification)
    if package['version'] != 'version:3@' + version:
        raise ValueError('gperf source does not match Chromium package version')
    source_sha256 = hashlib.sha256(fetch(source_url)).hexdigest()
    sources.append({
        'type': 'archive', 'url': source_url, 'sha256': source_sha256,
        'dest': 'gperf-src', 'only-arches': ['aarch64'],
    })
    for path in ('3pp/gperf/install.sh', '3pp/gperf/README.chromium'):
        sources.append({**inline(Path(path).name, recipes[path]),
                        'dest': 'gperf-src/3pp', 'only-arches': ['aarch64']})
    sources.append(inline('gperf-version', version + '\n'))
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
    sources.extend(gperf_sources(deps))
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
            'if [ "$FLATPAK_ARCH" = aarch64 ]; then (cd gperf-src && _3PP_VERSION="$(cat ../gperf-version)" bash 3pp/install.sh "${PWD}/../gperf"); fi',
            'if [ "$FLATPAK_ARCH" = x86_64 ]; then install -Dm755 clang-format /app/toolchains/clang-format; else ln -s llvm/bin/clang-format /app/toolchains/clang-format; fi',
            'if [ "$FLATPAK_ARCH" = aarch64 ]; then mv jdk/bin/java jdk/bin/java.chromium; install -m755 jdk-java-wrapper jdk/bin/java; fi',
            # Keep Chromium's patched declarations; replace only the native compiler.
            'if [ "$FLATPAK_ARCH" = aarch64 ]; then install -m755 typescript-arm64/lib/tsc typescript/lib/tsc; fi',
            # Match update_node_binaries: Chromium removes the package managers.
            'if [ "$FLATPAK_ARCH" = aarch64 ]; then rm -rf node/bin/npm node/bin/npx node/bin/corepack node/lib/node_modules/npm node/lib/node_modules/corepack; fi',
            'cp -a node go jdk typescript esbuild rollup_libs gperf node-version go-version jdk-version /app/toolchains/',
            # CIPD archives contain read-only binaries; eu-strip needs write access.
            'chmod -R u+w /app/toolchains/node /app/toolchains/go /app/toolchains/jdk /app/toolchains/typescript /app/toolchains/esbuild /app/toolchains/rollup_libs /app/toolchains/gperf',
        ], 'cleanup': ['/toolchains'], 'sources': sources,
    }


def file_source(path):
    # Included modules resolve local sources relative to toolchains/.
    return {'type': 'file', 'path': '../' + path}


def inline(filename, contents):
    return {'type': 'inline', 'dest-filename': filename, 'contents': contents}


def github_archive(repo, commit, dest):
    url = f'https://codeload.github.com/{repo}/tar.gz/{commit}'
    checksum = hashlib.sha256(fetch(url)).hexdigest()
    return {
        'type': 'archive', 'archive-type': 'tar-gzip', 'url': url,
        'sha256': checksum, 'dest': dest,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version', help='Chromium version, without the UC package release')
    args = parser.parse_args()
    recipes = {path: github('chromium/chromium', args.version, path)
               for path in UPSTREAM_RECIPES}
    clang_update = recipes['tools/clang/scripts/update.py']
    clang_build = recipes['tools/clang/scripts/build.py']
    rust_update = recipes['tools/rust/update_rust.py']
    rust_build = recipes['tools/rust/build_rust.py']
    bindgen_build = recipes['tools/rust/build_bindgen.py']
    deps = github('chromium/chromium', args.version, 'DEPS')
    node_update = recipes['third_party/node/update_node_binaries']
    clang_revision = constant(clang_update, 'CLANG_REVISION')
    clang_package = f'{clang_revision}-{constant(clang_update, "CLANG_SUB_REVISION")}'
    rust_revision = constant(rust_update, 'RUST_REVISION')
    rust_package = f'{rust_revision}-{constant(rust_update, "RUST_SUB_REVISION")}-{clang_revision}'
    bindgen_revision = constant(bindgen_build, 'BINDGEN_GIT_VERSION')
    crubit_revision = constant(rust_update, 'CRUBIT_REVISION')
    stage0 = verified_stage0(github('rust-lang/rust', rust_revision, 'src/stage0'), rust_update)

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
    llvm_patches, patch_sources, _ = prepare_patches(
        'llvm/llvm-project', llvm_commit,
        cherry_picks(clang_build, 'LLVM_DIR', 'llvm/llvm-project'), 'llvm', 'llvm')
    llvm_sources.extend(patch_sources)
    llvm_sources.extend([
        file_source('build-steps/llvm/0010-build.sh'),
        inline('clang-revision', clang_package + '\n'),
        inline('clang-commit', llvm_commit + '\n'),
    ])
    llvm = {
        'name': 'native-llvm', 'only-arches': ['aarch64'],
        'buildsystem': 'simple', 'build-commands': ['bash 0010-build.sh'],
        'cleanup': ['/toolchains'], 'sources': llvm_sources,
    }

    backtrace = submodule('rust-lang/rust', rust_revision, 'library/backtrace', 'rust-lang/backtrace-rs')
    rust_llvm = submodule('rust-lang/rust', rust_revision, 'src/llvm-project', 'rust-lang/llvm-project')
    cargo_revision = submodule('rust-lang/rust', rust_revision, 'src/tools/cargo', 'rust-lang/cargo')
    sources = [
        github_archive('rust-lang/rust', rust_revision, 'rust'),
        github_archive('rust-lang/backtrace-rs', backtrace, 'rust/library/backtrace'),
        github_archive('rust-lang/llvm-project', rust_llvm, 'rust/src/llvm-project'),
        github_archive('rust-lang/cargo', cargo_revision, 'rust/src/tools/cargo'),
        github_archive('rust-lang/rust-bindgen', bindgen_revision, 'bindgen'),
        github_archive('google/crubit', crubit_revision, 'crubit'),
    ]
    rust_patches, patch_sources, patched_rust_files = prepare_patches(
        'rust-lang/rust', rust_revision,
        cherry_picks(rust_build, 'RUST_SRC_DIR', 'rust-lang/rust'), 'rust', 'rust')
    sources.extend(patch_sources)
    # Scope copyright metadata to the workspaces used by our offline build.
    sources.append({
        'type': 'patch', 'path': 'offline-rust-copyright.patch',
        'options': ['-d', 'rust'],
    })
    # Rust's own LLVM submodule supplies builtins/profiler sources. The compiler
    # backend still links the separately built Chromium LLVM via llvm-config.
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

    # Compiler, bootstrap, stdlib, bindgen and Crubit are separate Cargo workspaces.
    crates = {}
    coordinates = {}
    for repo, revision, lock in (
        ('rust-lang/rust', rust_revision, 'Cargo.lock'),
        ('rust-lang/rust', rust_revision, 'src/bootstrap/Cargo.lock'),
        ('rust-lang/rust', rust_revision, 'library/Cargo.lock'),
        ('rust-lang/cargo', cargo_revision, 'Cargo.lock'),
        ('rust-lang/rust-bindgen', bindgen_revision, 'Cargo.lock'),
        ('google/crubit', crubit_revision, 'Cargo.lock'),
    ):
        contents = (patched_rust_files[lock]
                    if repo == 'rust-lang/rust' and lock in patched_rust_files
                    else github(repo, revision, lock))
        if contents is None:
            raise ValueError(f'Upstream patch removed required lockfile: {lock}')
        for package in tomllib.loads(contents.decode())['package']:
            if 'source' not in package:
                continue
            if package['source'] != 'registry+https://github.com/rust-lang/crates.io-index':
                raise ValueError(f'Unsupported Cargo source: {package["source"]}')
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
        file_source('build-steps/rust/0025-configure.py'),
        file_source('build-steps/rust/0030-build.sh'),
        file_source('build-steps/rust/0040-build-crubit.sh'),
        inline('crate-checksums.json', json.dumps(crates, sort_keys=True) + '\n'),
        inline('rust-revision', rust_package + '\n'),
        inline('rust-commit', rust_revision + '\n'),
        inline('config.toml.template', recipes['tools/rust/config.toml.template'].decode()),
    ])
    rust = {
        'name': 'native-rust', 'only-arches': ['aarch64'],
        'buildsystem': 'simple', 'build-commands': [
            'bash 0010-install-bootstrap.sh',
            'python3 0020-prepare-vendor.py',
            'python3 0025-configure.py',
            'bash 0030-build.sh',
            'bash 0040-build-crubit.sh',
        ],
        'cleanup': ['/toolchains'], 'sources': sources,
    }
    tools = build_tools(deps, node_update)
    for filename, patch in (llvm_patches | rust_patches).items():
        (ROOT / filename).write_bytes(patch)
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
