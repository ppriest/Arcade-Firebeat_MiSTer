#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write releases/Firebeat_disc_slots.zip: Main_MiSTer's remembered disc mounts for every set in
gen_mra.SETS, so each set boots with its discs already in the OSD's slots.

    python scripts/gen_slots.py

The zip holds config/<set>.s0 (Program CD) and config/<set>.s1 (Audio CD / Data DVD), to unzip
at /media/fat. Each file is 1,024 bytes: the image's path from /media/fat, NUL-terminated and
zero-padded, as Main writes them. A set's discs are in games/<set>/; a set whose two discs are an
earlier set's (the license-expired clones) points at that set's folder.
"""
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from gen_mra import SETS  # noqa: E402

SIZE = 1024
OUT = REPO / "releases" / "Firebeat_disc_slots.zip"


def slot(path):
    b = path.encode() + b"\0"
    assert len(b) <= SIZE, path
    return b + bytes(SIZE - len(b))


def main():
    folder = {}                         # disc pair -> the first set holding it
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for name, s in SETS.items():
            cds = tuple(s["cds"])
            d = folder.setdefault(cds, name)
            for i, cd in enumerate(cds):
                z.writestr(f"config/{name}.s{i}", slot(f"games/{d}/{cd}.chd"))
            print(f"{name}: games/{d}/{cds[0]}.chd, games/{d}/{cds[1]}.chd")
    print(f"{OUT}: {2 * len(SETS)} files")


if __name__ == "__main__":
    main()
