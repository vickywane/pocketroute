#!/usr/bin/env python3
"""Copy the PWA into build/web for Firebase Hosting.

`apps/web/data/` holds a symlink to the Tube map in `shared/fixtures/`.
Hosting doesn't follow symlinks, so this copies the real file in place.
Tests and editor files are left out.
"""

import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "apps/web"
OUTPUT = ROOT / "build/web"

if OUTPUT.exists():
    shutil.rmtree(OUTPUT)
shutil.copytree(SOURCE, OUTPUT, symlinks=False,
                ignore=shutil.ignore_patterns("*.test.mjs", ".DS_Store", "firebase-config.json"))

network = OUTPUT / "data/london-underground-network-v1.json"
if not network.is_file() or network.is_symlink():
    raise SystemExit(f"Missing Tube map in build: {network}")
print(f"Built {OUTPUT.relative_to(ROOT)} ({sum(1 for p in OUTPUT.rglob('*') if p.is_file())} files)")
