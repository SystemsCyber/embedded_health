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
    echo "==> installing systemd unit"
    install -m 0644 "$SRC_DIR/node-health-agent.service" \
        /etc/systemd/system/node-health-agent.service
    # nogroup is called nobody on some minimal images.
    getent group nogroup >/dev/null 2>&1 || \
        sed -i 's/^Group=nogroup$/Group=nobody/' /etc/systemd/system/node-health-agent.service
    systemctl daemon-reload
    systemctl enable --now node-health-agent.service
    systemctl restart node-health-agent.service
    sleep 1
    systemctl --no-pager --lines=5 status node-health-agent.service || true
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
