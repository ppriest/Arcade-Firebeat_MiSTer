#!/bin/bash
# Scripts menu: switches on the PS2 ParaParaParadise controller (USB 0507:0011) now, and again
# whenever it is plugged in, until the MiSTer restarts. ppp_controller_boot.sh starts it at boot.
BIN=/media/fat/games/ppp_enable/ppp_enable

if [ ! -x "$BIN" ]; then
	echo "$BIN is missing: unzip releases/ppp_controller_*.zip onto the SD card."
	exit 1
fi

if pidof ppp_enable >/dev/null; then
	echo "Already running: the controller is enabled whenever it is attached."
else
	setsid "$BIN" -d >/dev/null 2>&1 < /dev/null &
	echo "Started: the controller is enabled now and whenever it is attached."
fi
sleep 2
"$BIN"
