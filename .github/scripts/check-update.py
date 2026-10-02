#!/usr/bin/env python3
"""Select a newer UC tag only when its matching Linux source is available."""

import os
from pathlib import Path
import re
import subprocess
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
METAINFO = ROOT / 'io.github.ungoogled_software.ungoogled_chromium.metainfo.xml'
UPSTREAM = 'https://github.com/ungoogled-software/ungoogled-chromium'
TARBALLS = 'https://github.com/chromium-linux-tarballs/chromium-tarballs/releases/download'
VERSION = re.compile(r'[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+')


def version_key(version):
    if not VERSION.fullmatch(version):
        raise ValueError(f'Invalid Ungoogled Chromium version: {version}')
    return tuple(int(part) for part in re.split(r'[.-]', version))


def newer_tags(output, current):
    """Sort numerically, including the package revision; prefer peeled commits."""
    tags = {}
    for line in output.splitlines():
        commit, ref = line.split()
        name = ref.removeprefix('refs/tags/').removesuffix('^{}')
        if not VERSION.fullmatch(name):
            continue
        if not re.fullmatch(r'[0-9a-f]{40}', commit):
            raise ValueError(f'Invalid upstream commit: {commit}')
        if name not in tags or ref.endswith('^{}'):
            tags[name] = commit
    return sorted(
        ((name, commit) for name, commit in tags.items()
         if version_key(name) > version_key(current)),
        key=lambda tag: version_key(tag[0]), reverse=True,
    )


def sources_available(version):
    chromium = version.rsplit('-', 1)[0]
    url = f'{TARBALLS}/{chromium}/chromium-{chromium}-linux.tar.xz'
    try:
        # HEAD avoids downloading the multi-gigabyte archive.
        with urlopen(Request(url, method='HEAD'), timeout=60):
            pass
        with urlopen(url + '.hashes', timeout=60) as response:
            hashes = response.read().decode()
    except HTTPError as error:
        if error.code == 404:
            return False
        raise  # Authentication, rate limits and server failures are not "no update".
    if not re.search(r'^sha256\s+[0-9a-fA-F]{64}(?:\s|$)', hashes, re.MULTILINE):
        raise ValueError(f'Missing or invalid SHA256 in {url}.hashes')
    return True


def select_update(output, current, available=sources_available):
    # Consider older eligible tags too if the newest tarball is still publishing.
    for version, commit in newer_tags(output, current):
        if available(version):
            return version, commit
        print(f'Waiting for Linux sources for {version}')
    return None


def main():
    releases = ET.parse(METAINFO).findall('./releases/release')
    current = max((release.attrib['version'] for release in releases), key=version_key)
    result = subprocess.run(
        ['git', 'ls-remote', '--tags', UPSTREAM],
        check=True, capture_output=True, text=True, timeout=120,
    )
    update = select_update(result.stdout, current)
    if update is None:
        print(f'No ready update newer than {current}')
        return
    version, commit = update
    print(f'Update available: {current} -> {version} ({commit})')
    if 'GITHUB_OUTPUT' in os.environ:
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'version={version}\ncommit={commit}\n')


if __name__ == '__main__':
    main()
