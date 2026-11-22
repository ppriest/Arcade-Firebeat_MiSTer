#!/bin/bash
# Scripts menu: adds ppp_enable to linux/user-startup.sh, so the PS2 ParaParaParadise controller is
# enabled from boot; run again to remove it.
BIN=/media/fat/Scripts/ppp_enable
STARTUP=/media/fat/linux/user-startup.sh
TAG="# ParaParaParadise controller (ppp_enable)"

if [ ! -x "$BIN" ]; then
	echo "$BIN is missing: copy ppp_enable next to this script."
	exit 1
fi

if [ -f "$STARTUP" ] && grep -qF "$TAG" "$STARTUP"; then
	grep -vF "$TAG" "$STARTUP" > "$STARTUP.tmp" && mv "$STARTUP.tmp" "$STARTUP"
	echo "Removed from $STARTUP: the controller is no longer enabled at boot."
else
	[ -f "$STARTUP" ] || printf '#!/bin/sh\n' > "$STARTUP"
	echo "[ -x $BIN ] && setsid $BIN -d >/dev/null 2>&1 < /dev/null & $TAG" >> "$STARTUP"
	echo "Added to $STARTUP: the controller is enabled from the next boot."
	echo "Run this script again to remove it."
fi
sync
