#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the .mra for each set in SETS and check its image.

    python scripts/gen_mra.py [set ...]

The index-0 image is rtl/firebeat_sys.sv's download: the BIOS (512 KB, ROM_LOAD16_WORD_SWAP, so
each halfword's bytes swapped) and the DS1991 dongle image at 0x80000; for Pop'n Music (the
Firebeat_popn revision) the SPU's program (likewise swapped) at 0x80000, the dongle at
0x100000 and the set's RTC preset (MAME's `rtc` region, the RTC's NVRAM when there is no .nv) at
0x102000. The script builds that
image from the .mra with scripts/mra.py (mra-tools-c's semantics) and compares it byte for byte
with the files read directly; it writes nothing if they differ. <mameversion> comes from the configured MAME (coretools.mame_version).
The NVRAM file (index 4) is the three flash chips and the RTC in MAME's .nv format (4,152 bytes).

Parents go to releases/, MAME's clones to releases/_alternatives/_<parent's game>/ (kbh under
_Keyboardmania). A push of releases/ needs each <rbf>'s released bitstream (scripts/check_release_mras.py).
"""
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import mame_version, rompath  # noqa: E402
import mra  # noqa: E402

BIOS = ("977jaa03.21e", "7b83362a")
POPN_BIOS = ("a02jaa03.21e", "43ecc093")
POPN_SPU = ("a02jaa04.3q", "8c6000dd")
# Pop'n Music's nine buttons by their colours, then Firebeat.sv's FB_POPN J1 line
POPN_BUTTONS = ("White 1,Yellow 1,Green 1,Blue 1,Red,Blue 2,Green 2,Yellow 2,White 2,"
                "Coin,Test,Service,Pause")


def fast_boot(rom):
    """Patches skipping the BIOS's work RAM tests: in each `lis r3,0x8010; ori; lis r4,0x8200; ori;
    bl test; cmplwi r3,1; beq +0`, the bl becomes `li r3,0` (a pass) and the compare's immediate takes
    the byte difference, since the BIOS checks its byte sum (E100 ROM ERROR otherwise). With r3 = 0
    the compare gives LT for any immediate above 0, as the passing test's did. rom: big-endian."""
    out = []
    pat = bytes.fromhex("3c608010606300003c80820060840000")
    i = rom.find(pat)
    while i >= 0:
        bl, cmp = rom[i + 16:i + 20], rom[i + 20:i + 28]
        assert bl[0] >> 2 == 18 and bl[3] & 3 == 1 and cmp == bytes.fromhex("2803000141820000"), hex(i)
        t = 1 + sum(bl) - sum(bytes.fromhex("38600000"))
        assert 1 <= t <= 0x1FE, hex(i)
        lo = min(t, 0xFF)
        out += [(i + 16, bytes.fromhex("38600000")), (i + 22, bytes([t - lo, lo]))]
        i = rom.find(pat, i + 1)
    assert len(out) == 4, f"{len(out) // 2} RAM test calls"
    return out


def popn(desc, year, dongle, rtc, cds, cabinet=0, zip=None):
    """A Pop'n Music set; a clone (zip= its parent's) under its parent's _alternatives folder."""
    s = dict(desc=desc, file=desc, bios=POPN_BIOS, dongle=dongle, spu=POPN_SPU, rtc=("rtc", rtc),
             cds=cds, cabinet=cabinet, year=year)
    if zip:
        s.update(zip=zip, alt="_" + POPN_PARENTS[zip])
    return s


KBM_BIOS = ("974a03.21e", "ef9a932d")
# Firebeat.sv's FB_KBM J1 line; the keys are the keyboard's (rtl/kbm_keys.sv)
KBM_BUTTONS = "Start,Coin,Test,Service,Pause"


def kbm(desc, year, dongle, cds, cabinet=2, zip=None, preset=None, english=False, alt=None):
    """A Keyboardmania set: init_kbm_jp's cabinet 2, init_kbm_overseas' 3. preset: an RTC in MAME's .nv
    format under scripts/rtc/, put in the image after the dongle (MAME has no rtc region for these sets,
    and a blank RTC stops at E161). english: the program disc has the English instruction screens
    (rtl/board/fb_kbm_en.sv), the mod byte's bit 4, which shows the OSD's Instructions option."""
    if english:
        cabinet |= 0x10
    s = dict(desc=desc, file=desc, bios=KBM_BIOS, dongle=dongle, cds=cds, cabinet=cabinet, year=year,
             kbm=True)
    if alt:
        s["alt"] = alt
    if preset:
        s["preset"] = preset
    if zip:
        s["zip"] = zip
    return s


POPN_PARENTS = {"popnmt": "Pop'n Music Mickey Tunes", "popnanm": "Pop'n Music Animelo",
                "popnanm2": "Pop'n Music Animelo 2"}
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
    "popn4": dict(desc="Pop'n Music 4", file="Pop'n Music 4", bios=POPN_BIOS,
                  dongle=("gq986_gc986", "df7935c4"), spu=POPN_SPU,
                  rtc=("rtc", "4a5c946c"),
                  cds=("gq986jaa01", "gq986jaa02"), cabinet=0),
    "popn5": popn("Pop'n Music 5", 2000, ("gea04-ja_gca04-ja_gca04-jb.bin", "f48f62f7"), "adeba6fc",
                  ("a04jaa01", "a04jaa02")),
    # 0xC0 bytes, MAME's BAD_DUMP
    "popn6": popn("Pop'n Music 6", 2001, ("gqa16-ja", "f2094180"), "9935427c",
                  ("gqa16jaa01", "gqa16jaa02")),
    "popn7": popn("Pop'n Music 7", 2001, ("gcb00", "fbc3f534"), "fce30919", ("b00jab01", "b00jaa02")),
    "popn8": popn("Pop'n Music 8", 2002, ("gcb30-ja_gcb30-jb", "5bcd854f"), "1a91f33a",
                  ("gqb30jaa01", "gqb30jaa02")),
    # init_popn_rental
    "popnmt": popn("Pop'n Music Mickey Tunes", 2000, ("gq976", "c626cf9a"), "a51bdc10",
                   ("976jaa01", "976jaa02"), cabinet=6),
    "popnmt2": popn("Pop'n Music Mickey Tunes!", 2000, ("gq976", "c626cf9a"), "a51bdc10",
                    ("976jba01", "976jaa02"), cabinet=6, zip="popnmt"),
    "popnanm": popn("Pop'n Music Animelo", 2000, ("gq987_gc987_forever", "ddd976b6"), "b08b454d",
                    ("gq987jaa01", "gq987jaa02")),
    "popnanma": popn("Pop'n Music Animelo (license expired)", 2000, ("popnanma/gq987_gc987", "c77bb0fc"),
                     "b08b454d", ("gq987jaa01", "gq987jaa02"), zip="popnanm"),
    "popnanm2": popn("Pop'n Music Animelo 2 (JAC)", 2001, ("gca02ja_gca02jb_gea02ja_forever", "63b22ee0"),
                     "90fcfeab", ("a02jac01", "gea02jaa02")),
    "popnanm2a": popn("Pop'n Music Animelo 2 (JAC, license expired)", 2001,
                      ("popnanm2a/gca02ja_gca02jb_gea02ja", "7910e8aa"), "90fcfeab",
                      ("a02jac01", "gea02jaa02"), zip="popnanm2"),
    "popnanm2ja": popn("Pop'n Music Animelo 2 (JAA)", 2001, ("gca02ja_gca02jb_gea02ja_forever", "63b22ee0"),
                       "90fcfeab", ("a02jaa01", "gea02jaa02"), zip="popnanm2"),
    "popnanm2jaa": popn("Pop'n Music Animelo 2 (JAA, license expired)", 2001,
                        ("popnanm2a/gca02ja_gca02jb_gea02ja", "7910e8aa"), "90fcfeab",
                        ("a02jaa01", "gea02jaa02"), zip="popnanm2"),
    "kbm": kbm("Keyboardmania", 2000, ("gq974", "65e4886a"), ("gq974-ja c01", "gq974-ja a02"),
               preset="kbm.nv", english=True),
    "kbh": kbm("Keyboardheaven (Korea)", 2000, ("kbh/gu974", "748b8476"), ("gu974-ka a01", "gu974-ka a02"),
               cabinet=3, zip="kbm", preset="kbm.nv", english=True, alt="_Keyboardmania"),
    "kbm2nd": kbm("Keyboardmania 2nd Mix", 2000, ("gca01ja_gca01aa", "27f977cf"), ("a01 ja a01", "a01 ja a02"),
                  preset="kbm.nv"),
    "kbm3rd": kbm("Keyboardmania 3rd Mix", 2001, ("gca12-ja_gca12-aa.bin", "96b12482"), ("a12jaa01", "a12jaa02"),
                  preset="kbm.nv"),
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
    bname, bcrc = s.get("bios", BIOS)
    popn = "spu" in s
    with zipfile.ZipFile(zp) as z:
        bios = read_crc(z, bcrc)
        dongle = read_crc(z, s["dongle"][1])
        spu = read_crc(z, s["spu"][1]) if popn else b""
        rtc = read_crc(z, s["rtc"][1]) if popn else b""
    name = s["desc"]                   # MAME's title
    swap = lambda d: b"".join(d[i + 1:i + 2] + d[i:i + 1] for i in range(0, len(d), 2))
    if popn:
        layout = """the BIOS (ROM_LOAD16_WORD_SWAP), the SPU's program
         (likewise) at 0x80000, the dongle at 0x100000, the RTC preset at 0x102000 (the NVRAM
         file, loaded after, replaces it)"""
        spu_part = f"""
        <interleave output="16">
            <part name="{s['spu'][0]}" crc="{s['spu'][1]}" map="12"/>
        </interleave>"""
        discs = "the program CD, {} as the data DVD".format(s["cds"][1] + ".chd")
        rtc_part = f"""
        <part repeat="{0x2000 - len(dongle):#x}">FF</part>
        <part name="{s['rtc'][0]}" crc="{s['rtc'][1]}"/>"""
        buttons = POPN_BUTTONS
        cab = "06 rental (init_popn_rental)" if s["cabinet"] == 6 else "00 Japan (init_popn_jp)"
    else:
        layout = """the BIOS (ROM_LOAD16_WORD_SWAP), then the dongle at
         0x80000"""
        spu_part = rtc_part = ""
        discs = "the program CD, {} as the audio CD".format(s["cds"][1] + ".chd")
        buttons = "Sensor 1,Sensor 2,Sensor 3,Sensor 4,Sensor 5,Start,Coin,Test,Service,Pause"
        cab = "08 Japan, 09 overseas"
    players = 1
    if s.get("kbm"):
        buttons = KBM_BUTTONS
        players = 2
        if "preset" in s:
            rtc = (REPO / "scripts" / "rtc" / s["preset"]).read_bytes()
            assert len(rtc) == 0x1038, s["preset"]
            layout += """, the RTC preset at
         0x82000: scripts/rtc/{} (MAME's .nv after the Test menu's BACKUP CLEAR; the NVRAM file, loaded
         after, replaces it)""".format(s["preset"])
            lines = "".join("\n            " + " ".join(f"{b:02X}" for b in rtc[i:i + 32]) for i in range(0, len(rtc), 32))
            rtc_part = f"""
        <part repeat="{0x2000 - len(dongle):#x}">FF</part>
        <part>{lines}
        </part>"""
        cab = "02 Japan (init_kbm_jp), 03 overseas (init_kbm_overseas); bit 4 the English instruction screens"
    # not on Pop'n Music: with the RAM tests skipped some builds stop at the game's E121 SDRAM ERROR,
    # and the same build passes the startup check without the patches (docs/HACKS.md)
    patches = [] if popn else fast_boot(swap(bios))
    patch_part = "".join(f"""
        <patch offset="{o:#07x}">{' '.join(f'{b:02X}' for b in d)}</patch>""" for o, d in patches)
    if patches:
        patch_part = """
        <!-- fast boot (docs/HACKS.md): each work RAM test's bl as li r3,0, and the dead compare after
             it (beq +0) given the byte difference, so the BIOS's byte sum is unchanged -->""" + patch_part
    rbf = "Firebeat_popn" if popn else "Firebeat_kbm" if s.get("kbm") else "Firebeat_ppp"
    rotation = "vertical (ccw)" if s.get("kbm") else "horizontal"
    text = f"""<misterromdescription>
    <name>{name}</name>
    <setname>{setname}</setname>
    <rbf>{rbf}</rbf>
    <mameversion>{mamever}</mameversion>
    <year>{s.get('year', 2000)}</year>
    <manufacturer>Konami</manufacturer>
    <category>Rhythm</category>
    <rotation>{rotation}</rotation>

    <!-- rtl/firebeat_sys.sv's download: {layout}; written and checked by scripts/gen_mra.py. The discs go in the OSD's slots:
         {s['cds'][0]}.chd as {discs}. -->
    <rom index="0" zip="{zname}.zip" md5="none">
        <interleave output="16">
            <part name="{bname}" crc="{bcrc}" map="12"/>
        </interleave>{spu_part}
        <part name="{s['dongle'][0]}" crc="{s['dongle'][1]}"/>{rtc_part}{patch_part}
    </rom>
    <!-- the cabinet register's nibble (firebeat.cpp cabinet_r; Firebeat.sv): {cab} -->
    <rom index="1">
        <part>{s.get('cabinet', 8):02X}</part>
    </rom>
    <!-- the three flash chips (6 MB) and the RTC (MAME's .nv, 4,152 bytes): the installed game and its
         settings (rtl/firebeat_sys.sv, ioctl index 4) -->
    <nvram index="4" size="{NVRAM_SIZE}"/>
    <!-- Firebeat.sv's J1 line: joystick bit 4 + i is name i -->
    <buttons names="{buttons}" count="{players}"/>
</misterromdescription>
"""
    sub = s["dir"] if "dir" in s else ("_alternatives/" + s["alt"] if "alt" in s else "")
    out = (REPO / "releases" / sub / f"{s['file']}.mra").resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    tmp.write_text(text)
    ref = swap(bios) + swap(spu) + dongle + ((bytes([0xFF]) * (0x2000 - len(dongle)) + rtc) if rtc else b"")
    ref = bytearray(ref)
    for o, d in patches:
        ref[o:o + len(d)] = d
    assert sum(ref[:len(bios)]) == sum(bios), setname
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
