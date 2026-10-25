#!/bin/bash
# Build the Main_MiSTer that serves this core's CHDs (branch firebeat-chd, worktree
# E:/Main_MiSTer-firebeat) in WSL Ubuntu with ARM GCC 10.2 (installed in ~/mister-gcc by the repo's
# setup_default_toolchain.sh; `make` from apt). Run from Windows:
#     MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash /mnt/e/Arcade-Firebeat_MiSTer/scripts/main_mister/build_main.sh
# The MiSTer runs it as /media/fat/MiSTer_Firebeat, chosen for this core only by a MiSTer.ini
# section:  [Firebeat*]  main=MiSTer_Firebeat
set -e
export PATH="$HOME/mister-gcc/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin:/usr/bin:/bin"
mkdir -p ~/mm
rsync -a --delete --exclude .git /mnt/e/Main_MiSTer-firebeat/ ~/mm/
cd ~/mm
set +e
make -j16 > build.log 2>&1
echo "exit=$?"
grep -i -E "error|firebeat.*warning" build.log | head -10
ls -l bin/MiSTer
file bin/MiSTer 2>/dev/null
cp bin/MiSTer /mnt/e/Main_MiSTer-firebeat/MiSTer_firebeat && echo "copied to E:/Main_MiSTer-firebeat/MiSTer_firebeat"
