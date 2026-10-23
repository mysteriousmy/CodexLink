#!/usr/bin/env python3
"""Ordinary Native AOT build: glibc Linux / Windows, without Docker or UPX."""

import argparse
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rids', nargs='+', choices=('linux-x64', 'linux-arm64', 'win-x64', 'win-arm64'), default=['linux-x64'])
    parser.add_argument('--configuration', choices=('Debug', 'Release'), default='Release')
    args = parser.parse_args()
    dotnet = shutil.which('dotnet') or 'dotnet'
    for rid in dict.fromkeys(args.rids):
        output = ROOT / 'artifacts' / 'aot' / args.configuration / rid
        subprocess.run([dotnet, 'publish', str(ROOT / 'server/CodexLink.Server'),
                        '-c', args.configuration, '-r', rid, '-o', str(output)],
                       cwd=ROOT, check=True)
        print('Ordinary Native AOT output:', output, flush=True)


if __name__ == '__main__':
    main()
