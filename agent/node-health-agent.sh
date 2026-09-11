#!/bin/sh
# ---------------------------------------------------------------------------
# node-health-agent.sh -- heartbeat agent for embedded Linux nodes
#
# Sends a small JSON heartbeat to the health service so the dashboard can show
# that this node is alive, and at what address it is reachable.
#
# Deliberately POSIX /bin/sh (works under BusyBox ash on stripped-down images),
# with no dependency beyond curl or wget and the files in /proc and /sys.
#
# Network cost: ~300 B out + ~60 B in per beat.  At the default 60 s interval
# that is about 6 B/s per node.  A start-up jitter keeps a rack of devices that
# boot together from synchronising into a thundering herd, and failures back
# off exponentially so a server outage does not turn into a retry storm.
# ---------------------------------------------------------------------------

set -u

AGENT_VERSION="1.0.0"
CONFIG_FILE="${NHA_CONFIG:-/etc/embedded-health/agent.conf}"

# ---- defaults (override in $CONFIG_FILE) ----------------------------------
HEALTH_URL="http://daily-server.research.colostate.edu/embedded_health/api/heartbeat"
INTERVAL=60           # seconds between heartbeats
IFACE=""              # network interface to report; auto-detected when empty
TAGS=""               # comma-separated free-form labels, e.g. "lab-b,bbb,cyber"
MODEL=""              # override the auto-detected hardware model
TIMEOUT=10            # per-request timeout, seconds
MAX_BACKOFF=600       # cap on the retry interval after repeated failures
ONESHOT=0             # 1 = send a single heartbeat and exit (for cron/testing)

# shellcheck source=/dev/null
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

[ "${1:-}" = "--once" ] && ONESHOT=1
[ "${1:-}" = "--version" ] && { echo "node-health-agent $AGENT_VERSION"; exit 0; }

log() { echo "$*" >&2; }   # systemd captures stderr into the journal

# ---- HTTP client ----------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
    HTTP=curl
elif command -v wget >/dev/null 2>&1; then
    HTTP=wget
else
    log "fatal: neither curl nor wget is installed"
    exit 1
fi

post_json() {
    # post_json <body> -> response body on stdout, non-zero on transport failure
    if [ "$HTTP" = curl ]; then
        curl -sS -f -X POST "$HEALTH_URL" \
             -H 'Content-Type: application/json' \
             -H "User-Agent: node-health-agent/$AGENT_VERSION" \
             --connect-timeout "$TIMEOUT" --max-time $((TIMEOUT * 2)) \
             --data-binary "$1" 2>/dev/null
    else
        wget -q -O - --timeout="$TIMEOUT" --tries=1 \
             --header='Content-Type: application/json' \
             --header="User-Agent: node-health-agent/$AGENT_VERSION" \
             --post-data="$1" "$HEALTH_URL" 2>/dev/null
    fi
}

# ---- identity -------------------------------------------------------------
detect_iface() {
    [ -n "$IFACE" ] && { echo "$IFACE"; return; }
    # Interface carrying the default route is the one the server sees us on.
    dev=$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "${dev:-}" ] && { echo "$dev"; return; }
    for cand in eth0 enp0s1 end0 usb0 wlan0; do
        [ -e "/sys/class/net/$cand" ] && { echo "$cand"; return; }
    done
    for p in /sys/class/net/*; do
        n=$(basename "$p"); [ "$n" = lo ] && continue
        echo "$n"; return
    done
    echo ""
}

iface_mac() {
    [ -n "${1:-}" ] && [ -r "/sys/class/net/$1/address" ] \
        && cat "/sys/class/net/$1/address" || echo ""
}

iface_ip() {
    addr=""
    if [ -n "${1:-}" ] && command -v ip >/dev/null 2>&1; then
        addr=$(ip -4 -o addr show dev "$1" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
    fi
    if [ -z "$addr" ] && [ -n "${1:-}" ] && command -v ifconfig >/dev/null 2>&1; then
        addr=$(ifconfig "$1" 2>/dev/null | awk '/inet (addr:)?/ {sub("addr:","",$2); print $2; exit}')
    fi
    # Last resort on very stripped images with neither iproute2 nor net-tools.
    # (The server also records the packet source address, so a blank here is
    # never fatal -- the dashboard falls back to what it observed.)
    if [ -z "$addr" ]; then
        addr=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$addr"
}

detect_model() {
    [ -n "$MODEL" ] && { echo "$MODEL"; return; }
    if [ -r /proc/device-tree/model ]; then
        tr -d '\000' < /proc/device-tree/model
    elif [ -r /sys/firmware/devicetree/base/model ]; then
        tr -d '\000' < /sys/firmware/devicetree/base/model
    elif [ -r /sys/class/dmi/id/product_name ]; then
        cat /sys/class/dmi/id/product_name
    else
        uname -m
    fi
}

# Stable identity, preferred in order: uplink MAC, machine-id, hostname.
IFACE_NAME=$(detect_iface)
MAC=$(iface_mac "$IFACE_NAME")
if [ -n "$MAC" ] && [ "$MAC" != "00:00:00:00:00:00" ]; then
    DEVICE_ID="$MAC"
elif [ -r /etc/machine-id ]; then
    DEVICE_ID=$(cat /etc/machine-id)
else
    DEVICE_ID=$(hostname)
fi

# Changes on every boot, so the server can count reboots.
if [ -r /proc/sys/kernel/random/boot_id ]; then
    BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
else
    BOOT_ID="$(date +%s)-$$"
fi

HOSTNAME_V=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)
MODEL_V=$(detect_model)
KERNEL_V=$(uname -r)

# ---- metrics --------------------------------------------------------------
read_uptime()  { awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0; }
read_load1()   { awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0; }

read_mem_pct() {
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
         END{ if (t>0) printf "%.1f", (t-a)*100/t; else print 0 }' /proc/meminfo 2>/dev/null || echo 0
}

read_disk_pct() {
    df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}' || echo 0
}

read_temp() {
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        v=$(cat "$z" 2>/dev/null) || continue
        case "$v" in ''|*[!0-9-]*) continue ;; esac
        [ "$v" -gt 1000 ] && v=$((v / 1000))
        [ "$v" -gt 0 ] && [ "$v" -lt 150 ] && { echo "$v"; return; }
    done
    echo ""
}

json_tags() {
    [ -z "$TAGS" ] && { echo "[]"; return; }
    printf '%s' "$TAGS" | awk -F, '{
        out="["; n=0
        for (i=1;i<=NF;i++) { gsub(/^[ \t]+|[ \t]+$/,"",$i); if ($i=="") continue;
            gsub(/"/,"",$i); if (n++) out=out ","; out=out "\"" $i "\"" }
        print out "]" }'
}

TAGS_JSON=$(json_tags)

build_payload() {
    ip_now=$(iface_ip "$IFACE_NAME")
    temp=$(read_temp)
    if [ -n "$temp" ]; then temp_field="\"temp_c\":$temp,"; else temp_field=""; fi
    cat <<EOF
{"device_id":"$DEVICE_ID","hostname":"$HOSTNAME_V","ip":"$ip_now","mac":"$MAC",
"model":"$MODEL_V","kernel":"$KERNEL_V","agent_version":"$AGENT_VERSION",
"boot_id":"$BOOT_ID","uptime_s":$(read_uptime),"load1":$(read_load1),
"mem_used_pct":$(read_mem_pct),"disk_used_pct":$(read_disk_pct),
${temp_field}"iface":"$IFACE_NAME","tags":$TAGS_JSON}
EOF
}

# ---- main loop ------------------------------------------------------------
log "node-health-agent $AGENT_VERSION starting: id=$DEVICE_ID iface=${IFACE_NAME:-none} url=$HEALTH_URL"

if [ "$ONESHOT" = 1 ]; then
    if post_json "$(build_payload)"; then echo; exit 0; fi
    log "heartbeat failed"; exit 1
fi

# Spread the fleet out across the interval instead of all beating at :00.
jitter=$(awk -v s="$DEVICE_ID$$" 'BEGIN{n=0; for(i=1;i<=length(s);i++) n+=index("abcdefghijklmnopqrstuvwxyz0123456789:",substr(s,i,1))*i; print n}')
sleep $(( jitter % INTERVAL ))

fails=0
while :; do
    if resp=$(post_json "$(build_payload)"); then
        [ "$fails" -gt 0 ] && log "heartbeat restored after $fails failure(s)"
        fails=0
        # The server owns the cadence: adopt whatever interval it reports.
        srv=$(printf '%s' "$resp" | tr -d ' ' | sed -n 's/.*"interval":\([0-9]\{1,\}\).*/\1/p')
        if [ -n "$srv" ] && [ "$srv" -ge 5 ] 2>/dev/null && [ "$srv" != "$INTERVAL" ]; then
            log "adopting server heartbeat interval: ${srv}s"
            INTERVAL="$srv"
        fi
        sleep "$INTERVAL"
    else
        fails=$((fails + 1))
        # 1x, 2x, 4x ... the interval, capped -- quiet during a server outage.
        backoff=$INTERVAL; n=1
        while [ "$n" -lt "$fails" ] && [ "$backoff" -lt "$MAX_BACKOFF" ]; do
            backoff=$((backoff * 2)); n=$((n + 1))
        done
        [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
        [ "$fails" -eq 1 ] || [ $((fails % 10)) -eq 0 ] \
            && log "heartbeat failed ($fails consecutive); retrying in ${backoff}s"
        sleep "$backoff"
    fi
done
