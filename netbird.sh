#!/bin/sh
# Thin executor: every decision is made in main.lua and handed over as NB_* env
# vars. Usage: netbird.sh install|start|up|down|status|stop|forget|uninstall

# Pinned on purpose. Updating NetBird means a new plugin release with new hashes,
# so the device only ever runs a binary we have tested and can verify.
VERSION="0.82.0"
SHA256_arm64="c2e5ccb5824cb29fe008a5a54854fd5926b89d3aaff7ab8721f77abf8e8b3e62"
SHA256_armv6="e44678a4e82321167b1c50e341abedf8a64261d70ff3faabe14dbebf7dc4b366"

HOME_DIR="${NB_HOME:?NB_HOME not set}"
RUN_DIR="${NB_RUN:?NB_RUN not set}"
BIN="$HOME_DIR/netbird"
# Unix sockets cannot live on the FAT partitions e-readers keep KOReader on.
SOCK="$RUN_DIR/netbird.sock"

nb() {
    "$BIN" --daemon-addr "unix://$SOCK" "$@"
}

# By pid rather than pgrep or killall, whose name matching differs across the
# BusyBox builds on these devices. The check against comm covers a reused pid:
# a pid file can outlive its process, and that pid can go to anything.
alive() {
    pid=$(cat "$RUN_DIR/$1" 2>/dev/null)
    [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "netbird" ] && echo "$pid"
}

daemon_pid() {
    alive daemon.pid
}

is_running() {
    [ -n "$(daemon_pid)" ]
}

# Alive and not a zombie, whatever its name. A child that died stays a zombie until
# this script exits, and kill -0 still succeeds on one.
exists() {
    state=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)
    [ -n "$state" ] && [ "$state" != Z ]
}

ensure_loopback() {
    # Some firmware leaves lo down. Netstack mode's SOCKS5 proxy binds to it.
    ifconfig lo 2>/dev/null | grep -q '127\.0\.0\.1' && return 0
    ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null
    # PocketBook only lets us do this through its NOPASSWD sudo.
    [ -x /ebrmain/cramfs/bin/sudo ] &&
        /ebrmain/cramfs/bin/sudo /sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null
    # iproute2 fallback (reMarkable, Cervantes)
    ip addr add 127.0.0.1/8 dev lo 2>/dev/null
    ip link set lo up 2>/dev/null
    return 0
}

export_ca_bundle() {
    # e-readers have no usable system CA store, but KOReader ships one. Never
    # export a path that does not exist.
    for ca in "$NB_KOREADER_DIR/data/ca-bundle.crt" \
              /mnt/us/koreader/data/ca-bundle.crt \
              /mnt/onboard/.adds/koreader/data/ca-bundle.crt; do
        if [ -r "$ca" ]; then
            SSL_CERT_FILE="$ca"
            export SSL_CERT_FILE
            return 0
        fi
    done
}

cmd_install() {
    export_ca_bundle
    if [ "$("$BIN" version 2>/dev/null)" = "$VERSION" ]; then
        echo OK
        return 0
    fi

    case "$(uname -m)" in
        aarch64|arm64) arch=arm64; want="$SHA256_arm64" ;;
        armv6*|armv7*|armv8*) arch=armv6; want="$SHA256_armv6" ;;
        *) echo "Unsupported CPU: $(uname -m)"; return 1 ;;
    esac

    mkdir -p "$HOME_DIR" || return 1
    archive="$HOME_DIR/netbird.tar.gz"
    url="https://github.com/netbirdio/netbird/releases/download/v$VERSION/netbird_${VERSION}_linux_$arch.tar.gz"
    rm -f "$archive"
    # Neither may know a CA store of its own. curl can be pointed at KOReader's.
    wget -q -O "$archive" "$url" 2>/dev/null ||
        curl -fsSL ${SSL_CERT_FILE:+--cacert "$SSL_CERT_FILE"} -o "$archive" "$url" 2>/dev/null
    if [ ! -s "$archive" ]; then
        rm -f "$archive"
        echo "Download failed"
        return 1
    fi

    # Fails closed: a device without sha256sum gets an empty hash and no install.
    got=$(sha256sum "$archive" 2>/dev/null | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
        rm -f "$archive"
        echo "Checksum mismatch, refusing to install"
        return 1
    fi

    # The old binary may be running, so swap it rather than write through it.
    rm -rf "$HOME_DIR/unpack"
    mkdir -p "$HOME_DIR/unpack"
    tar xzf "$archive" -C "$HOME_DIR/unpack" netbird
    rm -f "$archive"
    if ! mv -f "$HOME_DIR/unpack/netbird" "$BIN"; then
        rm -rf "$HOME_DIR/unpack"
        echo "Could not unpack (full disk?)"
        return 1
    fi
    rm -rf "$HOME_DIR/unpack"
    chmod +x "$BIN" 2>/dev/null

    if [ "$("$BIN" version 2>/dev/null)" != "$VERSION" ]; then
        echo "The binary does not run on this device"
        return 1
    fi
    echo OK
}

cmd_start() {
    is_running && return 0
    mkdir -p "$RUN_DIR" "$HOME_DIR/state" || return 1
    chmod 700 "$RUN_DIR" 2>/dev/null
    rm -f "$SOCK"
    ensure_loopback
    export_ca_bundle
    printf '%s' "$NB_MODE" > "$RUN_DIR/mode"

    [ "$NB_MODE" = "netstack" ] && export NB_USE_NETSTACK_MODE=true
    # Always userspace WireGuard. E-readers rarely have the kernel module, and DNS
    # works differently with it, so this keeps every device on the path we test.
    export NB_WG_KERNEL_DISABLED=true
    NB_STATE_DIR="$HOME_DIR/state" NB_LOG_MAX_SIZE_MB=1 "$BIN" service run \
        --daemon-addr "unix://$SOCK" \
        --config "$HOME_DIR/state/config.json" \
        --log-file "$HOME_DIR/netbird.log" \
        </dev/null >/dev/null 2>&1 &
    pid=$!
    echo "$pid" > "$RUN_DIR/daemon.pid"

    # A daemon that exits right away won't make a socket, so don't wait for one.
    # By existence, not comm: until the fork has exec'd, comm still says sh.
    i=0
    while [ ! -S "$SOCK" ]; do
        i=$((i+1))
        if [ "$i" -ge 15 ] || ! exists "$pid"; then
            kill "$pid" 2>/dev/null
            rm -f "$RUN_DIR/mode" "$RUN_DIR/daemon.pid"
            return 1
        fi
        sleep 1
    done
}

# Only one sign-in at a time. It must be gone before up.log is reused, because a
# killed `netbird up` still writes its "context canceled" error on the way out.
stop_up() {
    pid=$(alive up.pid)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null
        i=0
        while [ -d "/proc/$pid" ] && [ "$i" -lt 5 ]; do
            i=$((i+1))
            sleep 1
        done
    fi
    rm -f "$RUN_DIR/up.pid"
}

cmd_up() {
    stop_up

    # NetBird picks its sign-in flow from these. Seeing a desktop (Kindle firmware
    # runs X, so DISPLAY is set) it sends the browser to a localhost redirect that
    # only works on the device itself. The device code flow works from a phone.
    unset DISPLAY WAYLAND_DISPLAY BROWSER DESKTOP_SESSION XDG_CURRENT_DESKTOP XDG_SESSION_TYPE

    set --
    [ -s "$HOME_DIR/setup.key" ] && set -- --setup-key-file "$HOME_DIR/setup.key"
    # Netstack mode has no DNS to offer.
    if [ -n "$NB_USE_DNS" ] && [ "$(cat "$RUN_DIR/mode" 2>/dev/null)" = "tun" ]; then
        set -- "$@" --disable-dns=false
    else
        set -- "$@" --disable-dns
    fi
    # --network-monitor: Wi-Fi comes and goes on an e-reader like it does on a
    # laptop, where NetBird turns this on by default.
    # Backgrounded because SSO blocks until the user signs in; main.lua polls.
    # The binary itself, not through nb: a backgrounded function runs in a subshell,
    # and $! would then be that shell, which stop_up can't stop the sign-in through.
    "$BIN" --daemon-addr "unix://$SOCK" up --no-browser --network-monitor=true \
        --management-url "$NB_MANAGEMENT_URL" "$@" \
        </dev/null >"$RUN_DIR/up.log" 2>&1 &
    echo $! > "$RUN_DIR/up.pid"
}

cmd_stop() {
    stop_up
    # Starting the 40 MB binary only to find no daemon would delay a USB unmount.
    if is_running; then
        nb down >/dev/null 2>&1
        kill "$(daemon_pid)" 2>/dev/null
    fi

    # kill returns before the daemon exits, and it must be gone before KOReader
    # unmounts the partition it runs from for USB storage mode.
    i=0
    while is_running; do
        i=$((i+1))
        [ "$i" -ge 10 ] && kill -9 "$(daemon_pid)" 2>/dev/null
        [ "$i" -ge 20 ] && break
        sleep 1
    done
    rm -f "$SOCK" "$RUN_DIR/mode" "$RUN_DIR/up.log" "$RUN_DIR/daemon.pid" "$RUN_DIR/up.pid"
}

case "$1" in
    install) cmd_install ;;
    start) cmd_start ;;
    up) cmd_up ;;
    down) is_running && nb down >/dev/null 2>&1; true ;;
    status) nb status --json 2>/dev/null ;;
    stop) cmd_stop ;;
    forget) cmd_stop; rm -rf "$HOME_DIR/state" ;;
    uninstall) cmd_stop; rm -rf "$HOME_DIR" "$RUN_DIR" ;;
    *) echo "usage: $0 install|start|up|down|status|stop|forget|uninstall" >&2; exit 2 ;;
esac
