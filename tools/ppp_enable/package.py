"""Writes releases/ppp_controller_<YYYYMMDD>.zip, laid out for the SD card's root: the two
Scripts menu entries and the ppp_enable binary (build.sh) in games/ppp_enable, where they look."""
import time
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
FILES = [
    ("Scripts/ppp_controller.sh", HERE / "ppp_controller.sh"),
    ("Scripts/ppp_controller_boot.sh", HERE / "ppp_controller_boot.sh"),
    ("games/ppp_enable/ppp_enable", HERE / "ppp_enable"),
]


def main():
    out = REPO / "releases" / ("ppp_controller_%s.zip" % time.strftime("%Y%m%d"))
    with zipfile.ZipFile(out, "w") as z:
        for name, src in FILES:
            data = src.read_bytes()
            if name.endswith(".sh"):
                data = data.replace(b"\r\n", b"\n")
            zi = zipfile.ZipInfo(name, time.localtime()[:6])
            zi.create_system = 3
            zi.external_attr = 0o100755 << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
    print("->", out)


if __name__ == "__main__":
    main()
