#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the .mra for each set in SETS and check its image.

    python scripts/gen_mra.py [set ...]

The index-0 image is rtl/firebeat_sys.sv's download: the BIOS (512 KB, ROM_LOAD16_WORD_SWAP, so
each halfword's bytes swapped) and the DS1991 dongle image at 0x80000. The script builds that
image from the .mra with scripts/mra.py (mra-tools-c's semantics) and compares it byte for byte
with the files read directly; it writes nothing if they differ. <mameversion> comes from the configured MAME (coretools.mame_version).
The NVRAM file (index 4) is the three flash chips and the RTC in MAME's .nv format (4,152 bytes).

Parents go to releases/, MAME's clones to releases/_alternatives/_ParaParaParadise/.
"""
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import mame_version, rompath  # noqa: E402
import mra  # noqa: E402

BIOS = ("977jaa03.21e", "7b83362a")
SETS = {
    "ppp11": dict(desc="ParaParaParadise v1.1", file="ParaParaParadise v1.1",
                  dongle=("gq977", "1cf40267"), cds=("gc977jaa01", "gc977jaa02")),
    "ppp": dict(desc="ParaParaParadise", file="ParaParaParadise",
                dongle=("gq977", "1cf40267"), cds=("977jaa01", "977jaa02")),
    "ppd": dict(desc="ParaParaDancing", file="ParaParaDancing",
                dongle=("gq977-ko", "b275de3c"), cds=("977kaa01", "977kaa02"),
                cabinet=9),
    # a clone: its dongle is in the parent's merged zip
    "ppp1mp": dict(desc="ParaParaParadise 1st Mix Plus", file="ParaParaParadise 1st Mix Plus",
                   zip="ppp", dongle=("ppp1mp/gqa11-ja", "207a99b2"), cds=("a11jaa01", "a11jaa02"),
                   alt="_ParaParaParadise"),
}
NVRAM_SIZE = 0x600000 + 4152


def find_zip(romdirs, setname):
    for d in romdirs:
        p = Path(d) / f"{setname}.zip"
        if p.exists():
            return p
    return None


def read_crc(z, crc):
    for info in z.infolist():
        if f"{info.CRC:08x}" == crc:
            return z.read(info)
    raise KeyError(crc)


def write(setname, s, romdirs, mamever):
    zname = s.get("zip", setname)
    zp = find_zip(romdirs, zname)
    if zp is None:
        print(f"{setname}: no {zname}.zip in the ROM path, skipped")
        return
    with zipfile.ZipFile(zp) as z:
        bios = read_crc(z, BIOS[1])
        dongle = read_crc(z, s["dongle"][1])
    name = s["desc"]                   # MAME's title
    text = f"""<misterromdescription>
    <name>{name}</name>
    <setname>{setname}</setname>
    <rbf>Firebeat</rbf>
    <mameversion>{mamever}</mameversion>
    <year>2000</year>
    <manufacturer>Konami</manufacturer>
    <category>Rhythm</category>
    <rotation>horizontal</rotation>

    <!-- rtl/firebeat_sys.sv's download: the BIOS (ROM_LOAD16_WORD_SWAP), then the dongle at
         0x80000; written and checked by scripts/gen_mra.py. The discs go in the OSD's slots:
         {s['cds'][0]}.chd as the program CD, {s['cds'][1]}.chd as the audio CD. -->
    <rom index="0" zip="{zname}.zip" md5="none">
        <interleave output="16">
            <part name="{BIOS[0]}" crc="{BIOS[1]}" map="12"/>
        </interleave>
        <part name="{s['dongle'][0]}" crc="{s['dongle'][1]}"/>
    </rom>
    <!-- the cabinet register's nibble (firebeat.cpp cabinet_r; Firebeat.sv): 08 Japan, 09 overseas -->
    <rom index="1">
        <part>{s.get('cabinet', 8):02X}</part>
    </rom>
    <!-- the three flash chips (6 MB) and the RTC (MAME's .nv, 4,152 bytes): the installed game and its
         settings (rtl/firebeat_sys.sv, ioctl index 4) -->
    <nvram index="4" size="{NVRAM_SIZE}"/>
    <!-- Firebeat.sv's J1 line: joystick bit 4 + i is name i -->
    <buttons names="Sensor 1,Sensor 2,Sensor 3,Sensor 4,Sensor 5,Start,Coin,Test,Service,Pause" count="1"/>
</misterromdescription>
"""
    out = REPO / "releases" / ("_alternatives/" + s["alt"] if "alt" in s else "") / f"{s['file']}.mra"
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    tmp.write_text(text)
    ref = b"".join(bios[i + 1:i + 2] + bios[i:i + 1] for i in range(0, len(bios), 2)) + dongle
    img = mra.build_image(str(tmp), [str(zp)])
    if img != ref:
        n = next((i for i in range(min(len(img), len(ref))) if img[i] != ref[i]), min(len(img), len(ref)))
        tmp.unlink()
        sys.exit(f"{setname}: image differs from the reference at {n:#x} (sizes {len(img):#x}, {len(ref):#x})")
    tmp.replace(out)
    print(f"{out}: image {len(img):#x} bytes, identical to the files' (BIOS halfwords swapped)")


def main():
    romdirs = rompath().split(";")
    mamever = mame_version()
    if not mamever:
        sys.exit("MAME does not answer: check MAME_DIR/MAME_EXE")
    for name in sys.argv[1:] or list(SETS):
        write(name, SETS[name], romdirs, mamever)


if __name__ == "__main__":
    main()
