#!/bin/sh
# ---------------------------------------------------------------------------
# install-agent.sh -- install the heartbeat agent on an embedded node
#
#   sudo ./install-agent.sh [--url URL] [--interval N] [--tags a,b] [--iface eth0]
#
# Idempotent: safe to re-run to upgrade the agent or change its settings.
# Falls back to a BusyBox init script when systemd is not present.
# ---------------------------------------------------------------------------
set -eu

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=/usr/local/sbin/node-health-agent.sh
CONF_DIR=/etc/embedded-health
CONF=$CONF_DIR/agent.conf

URL=""; INTERVAL=""; TAGS=""; IFACE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --url)      URL="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --tags)     TAGS="$2"; shift 2 ;;
        --iface)    IFACE="$2"; shift 2 ;;
        -h|--help)  sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "error: run as root (sudo $0 ...)" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
    echo "error: install curl or wget first (apt-get install -y curl)" >&2; exit 1; }

echo "==> installing agent to $BIN"
# Minimal embedded images often ship without /usr/local/sbin, and `install`
# will not create the leading directory for us portably (BusyBox has no -D).
mkdir -p "$(dirname "$BIN")"
install -m 0755 "$SRC_DIR/node-health-agent.sh" "$BIN"

mkdir -p "$CONF_DIR"
if [ ! -f "$CONF" ]; then
    install -m 0644 "$SRC_DIR/agent.conf.example" "$CONF"
    echo "==> wrote default config $CONF"
fi

set_conf() {  # set_conf KEY VALUE
    [ -z "$2" ] && return 0
    if grep -q "^[#[:space:]]*$1=" "$CONF"; then
        sed -i "s|^[#[:space:]]*$1=.*|$1=\"$2\"|" "$CONF"
    else
        printf '%s="%s"\n' "$1" "$2" >> "$CONF"
    fi
    echo "    $1=$2"
}
set_conf HEALTH_URL "$URL"
set_conf INTERVAL   "$INTERVAL"
set_conf TAGS       "$TAGS"
set_conf IFACE      "$IFACE"

# --- send one heartbeat now so mistakes surface here, not silently later ---
echo "==> test heartbeat"
if NHA_CONFIG="$CONF" "$BIN" --once; then
    echo "    server accepted the heartbeat"
else
    echo "    WARNING: test heartbeat failed -- check HEALTH_URL in $CONF and" >&2
    echo "             that this node can reach the health server." >&2
fi

# --- boot integration -------------------------------------------------------
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    UNIT=/etc/systemd/system/node-health-agent.service
    SDVER=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')
    case "$SDVER" in ''|*[!0-9]*) SDVER=0 ;; esac
    echo "==> installing systemd unit (systemd ${SDVER:-unknown})"
    install -m 0644 "$SRC_DIR/node-health-agent.service" "$UNIT"

    # nogroup is called nobody on some minimal images.
    getent group nogroup >/dev/null 2>&1 || \
        sed -i 's/^Group=nogroup$/Group=nobody/' "$UNIT"

    # The unit is written for a current systemd.  Embedded images are often
    # many years behind -- Angstrom on AM335x ships systemd 196 (2012) -- and
    # an unknown directive there is at best ignored with a warning and at worst
    # stops the unit loading.  Strip anything the local version predates.  All
    # of it is defence in depth; none of it is needed for the agent to work.
    below() { [ "${SDVER:-0}" -lt "$1" ]; }
    drop()  { for k in "$@"; do sed -i "/^$k=/d" "$UNIT"; done; }

    if below 240; then drop SystemCallFilter SystemCallErrorNumber; fi
    if below 235; then drop LockPersonality; fi
    if below 233; then drop RestrictNamespaces; fi
    if below 232; then
        sed -i 's/^ProtectSystem=strict$/ProtectSystem=full/' "$UNIT"
        drop ProtectKernelTunables ProtectKernelModules ProtectControlGroups
    fi
    if below 231; then drop RestrictRealtime MemoryMax; fi
    if below 229; then drop StartLimitIntervalSec; fi
    if below 227; then drop TasksMax; fi
    if below 214; then drop ProtectSystem ProtectHome; fi
    if below 211; then drop RestrictAddressFamilies; fi
    if below 209; then drop NoNewPrivileges PrivateDevices; fi
    if below 200; then
        # network-online.target does not exist this far back, and a Wants= on a
        # missing unit can fail the job outright.
        sed -i 's/^After=network-online\.target$/After=network.target/' "$UNIT"
        drop Wants
    fi

    systemctl daemon-reload
    systemctl enable node-health-agent.service
    # NOT "enable --now": that flag arrived in systemd 220 and aborts here on
    # anything older.  A separate start does the same thing everywhere.
    systemctl restart node-health-agent.service
    sleep 2
    if systemctl is-active node-health-agent.service >/dev/null 2>&1; then
        echo "    service is running and enabled at boot"
    else
        echo "    WARNING: the service did not stay running." >&2
        systemctl status node-health-agent.service 2>&1 | head -20 >&2 || true
    fi
    echo
    echo "Done. Logs: journalctl -u node-health-agent -f"
else
    echo "==> systemd not found; installing SysV/BusyBox init script"
    cat > /etc/init.d/node-health-agent <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          node-health-agent
# Required-Start:    $network $remote_fs
# Required-Stop:     $network $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Embedded node health heartbeat agent
### END INIT INFO
BIN=/usr/local/sbin/node-health-agent.sh
PIDFILE=/var/run/node-health-agent.pid
case "$1" in
  start)
    echo "Starting node-health-agent"
    start-stop-daemon --start --background --make-pidfile --pidfile "$PIDFILE" \
        --exec "$BIN" 2>/dev/null || {
        "$BIN" >/var/log/node-health-agent.log 2>&1 &
        echo $! > "$PIDFILE"; }
    ;;
  stop)
    echo "Stopping node-health-agent"
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  status)  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null \
             && echo running || { echo stopped; exit 3; } ;;
  *) echo "usage: $0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF
    chmod 0755 /etc/init.d/node-health-agent
    if command -v update-rc.d >/dev/null 2>&1; then update-rc.d node-health-agent defaults
    elif command -v chkconfig  >/dev/null 2>&1; then chkconfig --add node-health-agent
    fi
    /etc/init.d/node-health-agent restart
    echo "Done. Logs: /var/log/node-health-agent.log"
fi
