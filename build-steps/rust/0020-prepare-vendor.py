#!/usr/bin/env python3
"""Finish the checksum-pinned crate sources supplied by flatpak-builder."""
import json
from pathlib import Path

checksums = json.loads(Path('crate-checksums.json').read_text())
for directory, checksum in checksums.items():
    # flatpak-builder verifies the complete archive before extracting it.
    (Path('vendor') / directory / '.cargo-checksum.json').write_text(
        json.dumps({'files': {}, 'package': checksum}) + '\n'
    )

config = '''[source.crates-io]
replace-with = "vendored-sources"
[source.vendored-sources]
directory = "{vendor}"
[net]
offline = true
'''.format(vendor=Path('vendor').resolve())
for root in (Path('rust'), Path('rust/library'), Path('rust/src/tools/cargo'),
             Path('bindgen'), Path('crubit')):
    (root / '.cargo').mkdir(exist_ok=True)
    (root / '.cargo/config.toml').write_text(config)

# Bootstrap also checks for this directory when build.vendor is enabled.
Path('rust/vendor').symlink_to('../vendor', target_is_directory=True)
