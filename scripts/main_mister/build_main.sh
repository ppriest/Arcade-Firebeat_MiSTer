#!/bin/bash
# Build the Main_MiSTer that serves this core's CHDs from the worktree in $MAIN (default
# /mnt/e/Main_MiSTer-firebeat, branch firebeat-chd) in WSL Ubuntu with ARM GCC 10.2 (installed in ~/mister-gcc by the repo's
# setup_default_toolchain.sh; `make` from apt). Run from Windows:
#     MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash /mnt/e/Arcade-Firebeat_MiSTer/scripts/main_mister/build_main.sh
# The MiSTer runs it as /media/fat/MiSTer_Firebeat, chosen for this core only by a MiSTer.ini
# section:  [Firebeat*]  main=MiSTer_Firebeat
set -e
export PATH="$HOME/mister-gcc/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin:/usr/bin:/bin"
MAIN=${MAIN:-/mnt/e/Main_MiSTer-firebeat}
mkdir -p ~/mm
rsync -a --delete --exclude .git "$MAIN"/ ~/mm/
cd ~/mm
set +e
make -j16 > build.log 2>&1
echo "exit=$?"
grep -i -E "error|firebeat.*warning" build.log | head -10
ls -l bin/MiSTer
file bin/MiSTer 2>/dev/null
cp bin/MiSTer "$MAIN"/MiSTer_firebeat && echo "copied to $MAIN/MiSTer_firebeat"
