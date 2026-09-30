#!/usr/bin/env python3
"""Report every missing source input before starting the Chromium build."""
from pathlib import Path
import subprocess
import sys


def missing_inputs(build_dir, targets):
    def ninja(*args):
        return subprocess.check_output(
            ['ninja', '-t', *args], cwd=build_dir, text=True
        ).splitlines()

    # Generated inputs may not exist yet; Ninja has a rule to create them.
    outputs = {line.rsplit(': ', 1)[0] for line in ninja('targets', 'all')}
    inputs = set(ninja('inputs', '-E', *targets))
    return sorted(
        name for name in inputs
        if name not in outputs and not (build_dir / name).exists()
    )


if __name__ == '__main__':
    missing = missing_inputs(Path('out/Release'), ['chrome', 'chrome_crashpad_handler'])
    if missing:
        print('Missing source inputs (no Ninja rule to generate them):', file=sys.stderr)
        for name in missing:
            print(f'  {name}', file=sys.stderr)
        sys.exit(1)
