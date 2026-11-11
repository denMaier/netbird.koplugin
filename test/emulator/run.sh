#!/bin/sh
# Run the plugin in KOReader's desktop emulator, driven by netbirdtest.koplugin.
# Usage: run.sh <koreader-dev dir>
#
# The dir holds an extracted KOReader AppImage and a sysroot with Xvfb and proot:
#   <dir>/squashfs-root/usr/lib/koreader/reader.lua
#   <dir>/sysroot/usr/bin/{Xvfb,proot,xkbcomp}
# Nothing in it is changed: the plugin is loaded from a fresh data dir (KO_HOME).
# Screenshots and results go to test/emulator/out/.
set -u
DEV=$(cd "${1:?usage: $0 <koreader-dev dir>}" && pwd) || exit 1
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
RUNTIME="$DEV/squashfs-root/usr/lib/koreader"
SYSROOT="$DEV/sysroot"
OUT="$HERE/out"
RUN_DIR=/tmp/netbird-koreader
[ -x "$RUNTIME/reader.lua" ] || { echo "No KOReader runtime in $RUNTIME"; exit 1; }

export PATH="$SYSROOT/usr/bin:$SYSROOT/bin:$PATH"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib/x86_64-linux-gnu:$SYSROOT/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# One emulator per runtime: other projects' launchers take the same lock.
exec 9>"$DEV/runtime.lock"
flock -n 9 || { echo "The emulator runtime is in use"; exit 1; }

stop_leftovers() {
    pid=$(cat "$RUN_DIR/daemon.pid" 2>/dev/null)
    [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = netbird ] && kill "$pid"
    rm -rf "$RUN_DIR"
}
stop_leftovers

rm -rf "$OUT"
mkdir -p "$OUT/state/plugins" "$OUT/books"
ln -s "$REPO" "$OUT/state/plugins/netbird.koplugin"
ln -s "$HERE/netbirdtest.koplugin" "$OUT/state/plugins/netbirdtest.koplugin"
printf 'A short book.\n\nIt only needs to open.\n' > "$OUT/books/sample.txt"

# A virtual display. Xvfb looks for xkbcomp and its keymaps under /usr; proot
# shows it the sysroot's without root.
proot -b "$SYSROOT/usr/bin/xkbcomp:/usr/bin/xkbcomp" -b "$SYSROOT/usr/share/X11/xkb:/usr/share/X11/xkb" \
    Xvfb -displayfd 8 -screen 0 1600x2000x24 -nolisten tcp 8>"$OUT/display" 2>"$OUT/xvfb.log" 9>&- &
xvfb=$!
# proot doesn't pass TERM on to Xvfb, so stop both.
trap 'pkill -P $xvfb 2>/dev/null; kill $xvfb 2>/dev/null; stop_leftovers' EXIT
i=0
until [ -s "$OUT/display" ]; do
    i=$((i+1)); [ "$i" -ge 30 ] && { echo "Xvfb did not start, see $OUT/xvfb.log"; exit 1; }
    sleep 0.5
done

echo "KOReader: Kobo Clara size, 1072x1448 at 300 DPI, monochrome"
launch() {
    (
        cd "$RUNTIME" &&
        DISPLAY=":$(cat "$OUT/display")" KO_HOME="$OUT/state" SDL_AUDIODRIVER=dummy \
        EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300 EMULATE_BW_SCREEN=1 \
        NETBIRD_EMU_OUT="$OUT" NETBIRD_EMU_PHASE="$1" NETBIRD_EMU_FAKE="$HERE/fake-netbird" \
        NETBIRD_EMU_BOOK="$OUT/books/sample.txt" \
        timeout 300 ./reader.lua -d "$OUT/books" 9>&-
    ) >"$OUT/emulator-$1.log" 2>&1
}
status=0
expect() { # phase, exit code KOReader should give
    cat "$OUT/results-$1.txt" 2>/dev/null
    grep -q '^ALL PASSED' "$OUT/results-$1.txt" 2>/dev/null || status=1
    [ "$code" -eq "$2" ] || { echo "FAIL  KOReader exited with $code, see $OUT/emulator-$1.log"; status=1; }
}

# First run: everything a user does, ending in a restart (exit 85).
launch first; code=$?
expect first 85
pid=$(cat "$OUT/daemon.pid" 2>/dev/null)
if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    echo "PASS  a KOReader restart keeps the daemon"
else
    echo "FAIL  daemon ${pid:-?} gone after a restart"; status=1
fi

# Second run, as koreader.sh starts it again after a restart. Then a plain exit.
launch restart; code=$?
expect restart 0
if [ -n "$pid" ] && [ ! -d "/proc/$pid" ]; then
    echo "PASS  leaving KOReader stops the daemon"
else
    echo "FAIL  daemon ${pid:-?} still running after KOReader quit"; status=1
fi
if grep -q '\["want_connected"\] = true' "$OUT/state/settings/netbird.lua" 2>/dev/null; then
    echo "PASS  NetBird comes back on the next start"
else
    echo "FAIL  want_connected was not kept"; status=1
fi
echo "Screenshots and logs: $OUT"
exit $status
