#!/bin/bash
# Build and run chd_raw_check.cpp in WSL against the Main_MiSTer worktree (branch firebeat-chd).
#     MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash /mnt/e/Arcade-Firebeat_MiSTer/scripts/main_mister/chd_raw_check.sh A.chd A.bin [B.chd B.bin ...]
set -e
MAIN=/mnt/e/Main_MiSTer-firebeat
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HOME/chdcheck
mkdir -p "$OUT"
INC="-I$MAIN -I$MAIN/lib/libchdr/include -I$MAIN/lib/lzma -I$MAIN/lib/zstd/lib -I$MAIN/lib/miniz"
if [ ! -x "$OUT/chd_raw_check" ] || [ "$HERE/chd_raw_check.cpp" -nt "$OUT/chd_raw_check" ] || \
   [ "$MAIN/support/firebeat/firebeat.cpp" -nt "$OUT/chd_raw_check" ]; then
	cd "$OUT"
	rm -f *.o
	for c in "$MAIN"/lib/libchdr/*.c "$MAIN"/lib/lzma/*.c "$MAIN"/lib/zstd/lib/common/*.c \
	         "$MAIN"/lib/zstd/lib/decompress/*.c "$MAIN"/lib/miniz/*.c; do
		gcc -O2 -w $INC -D_7ZIP_ST -DZSTD_DISABLE_ASM -c "$c" -o "$(basename "${c%.*}")_$(echo "$c" | md5sum | cut -c1-6).o"
	done
	g++ -O2 -w $INC -c "$MAIN/support/chd/mister_chd.cpp" -o mister_chd.o
	g++ -O2 -w $INC -c "$MAIN/support/firebeat/firebeat.cpp" -o firebeat.o
	g++ -O2 -w $INC -c "$HERE/chd_raw_check.cpp" -o chd_raw_check.o
	g++ -o chd_raw_check *.o
fi
while [ $# -ge 2 ]; do
	echo "== $1"
	"$OUT/chd_raw_check" "$1" "$2"
	shift 2
done
