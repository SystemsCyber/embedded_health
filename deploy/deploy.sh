#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy.sh -- install / upgrade the embedded node health service
#
# Run on the production server (daily-server).  Idempotent: re-running it
# upgrades the code in place, keeps the database and any hand-edited config,
# and restarts only what needs restarting.
#
#   sudo ./deploy/deploy.sh --repo https://github.com/SystemsCyber/embedded_health.git
#
# Or as a one-liner on a fresh box (it will clone the repo itself):
#   curl -fsSL https://raw.githubusercontent.com/SystemsCyber/embedded_health/main/deploy/deploy.sh \
#     | sudo bash -s -- --repo https://github.com/SystemsCyber/embedded_health.git
#
# Options:
#   --repo URL          git repository to deploy from
#   --branch NAME       branch/tag to check out            (default: main)
#   --dir PATH          install prefix                     (default: /opt/embedded-health)
#   --iface NAME        subnet-facing interface            (default: eth0)
#   --listen ADDR       bind address, overrides --iface detection
#   --server-name HOST  nginx server_name  (default: daily-server.research.colostate.edu)
#   --interval SECONDS  heartbeat cadence, first install only   (default: 60)
#   --no-nginx          skip all nginx configuration
#   --uninstall         remove services and nginx site (keeps the database)
# ---------------------------------------------------------------------------
set -Eeuo pipefail

REPO=""
BRANCH="main"
PREFIX="/opt/embedded-health"
IFACE="eth0"
LISTEN=""
SERVER_NAME="daily-server.research.colostate.edu"
INTERVAL="60"
DO_NGINX=1
UNINSTALL=0

SVC_USER="embedded-health"
SVC_NAME="embedded-health"
CONF_DIR="/etc/embedded-health"
PORT="8787"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""; }
step() { printf '\n%s==>%s %s\n' "$C_OK" "$C_OFF" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s  ! %s%s\n' "$C_WARN" "$*" "$C_OFF"; }
die()  { printf '%s  x %s%s\n' "$C_ERR" "$*" "$C_OFF" >&2; exit 1; }
trap 'die "failed at line $LINENO: ${BASH_COMMAND}"' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        REPO="$2"; shift 2 ;;
    --branch)      BRANCH="$2"; shift 2 ;;
    --dir)         PREFIX="$2"; shift 2 ;;
    --iface)       IFACE="$2"; shift 2 ;;
    --listen)      LISTEN="$2"; shift 2 ;;
    --server-name) SERVER_NAME="$2"; shift 2 ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    --no-nginx)    DO_NGINX=0; shift ;;
    --uninstall)   UNINSTALL=1; shift ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"
command -v systemctl >/dev/null || die "this deployer targets systemd hosts"

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ $UNINSTALL -eq 1 ]]; then
  step "removing $SVC_NAME"
  systemctl disable --now "$SVC_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SVC_NAME}.service"
  systemctl daemon-reload
  rm -f /etc/nginx/sites-enabled/embedded_health \
        /etc/nginx/sites-available/embedded_health \
        /etc/nginx/conf.d/embedded_health.conf \
        /etc/nginx/embedded_health_proxy.conf
  if nginx -t >/dev/null 2>&1; then systemctl reload nginx || true; else warn "nginx config left unreloaded"; fi
  info "removed. Code in $PREFIX and the database in /var/lib/embedded-health were kept."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
step "checking prerequisites"
if command -v apt-get >/dev/null; then
  PKGS=()
  command -v git >/dev/null       || PKGS+=(git)
  command -v curl >/dev/null      || PKGS+=(curl)
  command -v python3 >/dev/null   || PKGS+=(python3)
  python3 -c 'import venv' 2>/dev/null || PKGS+=(python3-venv)
  if [[ $DO_NGINX -eq 1 ]] && ! command -v nginx >/dev/null; then PKGS+=(nginx); fi
  if [[ ${#PKGS[@]} -gt 0 ]]; then
    info "installing: ${PKGS[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}"
  else
    info "all present"
  fi
elif command -v dnf >/dev/null || command -v yum >/dev/null; then
  YUM=$(command -v dnf || command -v yum)
  PKGS=()
  command -v git >/dev/null     || PKGS+=(git)
  command -v curl >/dev/null    || PKGS+=(curl)
  command -v python3 >/dev/null || PKGS+=(python3)
  if [[ $DO_NGINX -eq 1 ]] && ! command -v nginx >/dev/null; then PKGS+=(nginx); fi
  [[ ${#PKGS[@]} -gt 0 ]] && { info "installing: ${PKGS[*]}"; "$YUM" install -y -q "${PKGS[@]}"; } || info "all present"
else
  warn "unknown package manager; assuming git, python3, python3-venv and nginx are installed"
fi
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)' \
  || die "python3 >= 3.8 required (found $(python3 -V 2>&1))"

# ---------------------------------------------------------------------------
# 2. Resolve the bind address -- the service must only face the subnet
# ---------------------------------------------------------------------------
step "resolving listen address"
if [[ -z "$LISTEN" ]]; then
  [[ -e "/sys/class/net/$IFACE" ]] || die "interface '$IFACE' does not exist. Available: $(ls /sys/class/net | tr '\n' ' ') -- pass --iface or --listen"
  LISTEN=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
  [[ -n "$LISTEN" ]] || die "interface '$IFACE' has no IPv4 address yet; bring it up or pass --listen ADDR"
fi
info "$IFACE -> $LISTEN  (the service will not be reachable on any other interface)"

# ---------------------------------------------------------------------------
# 3. Source code
# ---------------------------------------------------------------------------
SRC_ROOT=""
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo "")
if [[ -n "$SELF_DIR" && -f "$SELF_DIR/../server/app.py" ]]; then
  SRC_ROOT=$(cd "$SELF_DIR/.." && pwd)
fi

step "syncing source into $PREFIX"
if [[ -n "$SRC_ROOT" && "$SRC_ROOT" != "$PREFIX" && -z "$REPO" ]]; then
  info "copying from the local checkout at $SRC_ROOT"
  mkdir -p "$PREFIX"
  for d in server agent deploy docs; do
    [[ -d "$SRC_ROOT/$d" ]] && { rm -rf "${PREFIX:?}/$d"; cp -a "$SRC_ROOT/$d" "$PREFIX/"; }
  done
  [[ -f "$SRC_ROOT/README.md" ]] && cp -a "$SRC_ROOT/README.md" "$PREFIX/"
elif [[ -n "$REPO" ]]; then
  if [[ -d "$PREFIX/.git" ]]; then
    info "updating existing clone ($BRANCH)"
    git -C "$PREFIX" remote set-url origin "$REPO"
    git -C "$PREFIX" fetch --depth 1 origin "$BRANCH"
    git -C "$PREFIX" checkout -q -B "$BRANCH" "origin/$BRANCH"
    git -C "$PREFIX" reset -q --hard "origin/$BRANCH"
  else
    info "cloning $REPO ($BRANCH)"
    rm -rf "$PREFIX"
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$PREFIX"
  fi
  info "at commit $(git -C "$PREFIX" rev-parse --short HEAD)"
elif [[ -f "$PREFIX/server/app.py" ]]; then
  info "using the existing install at $PREFIX (no --repo given)"
else
  die "nothing to deploy: pass --repo URL, or run this script from a checkout"
fi
[[ -f "$PREFIX/server/app.py" ]] || die "$PREFIX/server/app.py missing after sync"

# ---------------------------------------------------------------------------
# 4. Service account
# ---------------------------------------------------------------------------
step "service account"
if id -u "$SVC_USER" >/dev/null 2>&1; then
  info "$SVC_USER exists"
else
  useradd --system --no-create-home --home-dir /nonexistent \
          --shell /usr/sbin/nologin "$SVC_USER" 2>/dev/null \
    || useradd --system --no-create-home --home-dir /nonexistent \
               --shell /sbin/nologin "$SVC_USER"
  info "created $SVC_USER"
fi

# ---------------------------------------------------------------------------
# 5. Python environment
# ---------------------------------------------------------------------------
step "python environment"
[[ -x "$PREFIX/venv/bin/python" ]] || python3 -m venv "$PREFIX/venv"
"$PREFIX/venv/bin/pip" install --quiet --upgrade pip wheel
"$PREFIX/venv/bin/pip" install --quiet -r "$PREFIX/server/requirements.txt"
info "$("$PREFIX/venv/bin/python" -c 'from importlib.metadata import version as v; print("flask "+v("flask")+", gunicorn "+v("gunicorn"))')"

# Code is read-only to the service; only the state directory is writable.
chown -R root:root "$PREFIX"
chmod -R go-w "$PREFIX"
install -d -o "$SVC_USER" -g "$SVC_USER" -m 0750 /var/lib/embedded-health

# ---------------------------------------------------------------------------
# 6. Configuration
# ---------------------------------------------------------------------------
step "configuration"
install -d -m 0755 "$CONF_DIR"
if [[ -f "$CONF_DIR/server.env" ]]; then
  info "keeping existing $CONF_DIR/server.env"
else
  install -m 0644 "$PREFIX/deploy/server.env.example" "$CONF_DIR/server.env"
  sed -i "s/^EH_HEARTBEAT_INTERVAL=.*/EH_HEARTBEAT_INTERVAL=$INTERVAL/" "$CONF_DIR/server.env"
  info "wrote $CONF_DIR/server.env (heartbeat every ${INTERVAL}s)"
fi

# ---------------------------------------------------------------------------
# 7. systemd unit
# ---------------------------------------------------------------------------
step "systemd unit"
UNIT_SRC="$PREFIX/deploy/embedded-health.service"
UNIT_DST="/etc/systemd/system/${SVC_NAME}.service"
sed -e "s|/opt/embedded-health|$PREFIX|g" "$UNIT_SRC" > "$UNIT_DST"
chmod 0644 "$UNIT_DST"
systemctl daemon-reload
systemctl enable "$SVC_NAME" >/dev/null
systemctl restart "$SVC_NAME"

for _ in $(seq 1 25); do
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT/api/healthz" >/dev/null 2>&1 && break
  sleep 0.4
done
if curl -fsS --max-time 3 "http://127.0.0.1:$PORT/api/healthz" >/dev/null; then
  info "service healthy on 127.0.0.1:$PORT (enabled at boot, Restart=always)"
else
  journalctl -u "$SVC_NAME" --no-pager --lines=30 || true
  die "service did not come up; see the log above"
fi

# ---------------------------------------------------------------------------
# 8. nginx
# ---------------------------------------------------------------------------
if [[ $DO_NGINX -eq 1 ]]; then
  step "nginx"
  command -v nginx >/dev/null || die "nginx is not installed"
  install -m 0644 "$PREFIX/deploy/embedded_health_proxy.conf" /etc/nginx/embedded_health_proxy.conf

  RENDERED=$(mktemp)
  sed -e "s|@LISTEN@|$LISTEN|g" -e "s|@SERVER_NAME@|$SERVER_NAME|g" \
      "$PREFIX/deploy/nginx-embedded-health.conf.template" > "$RENDERED"

  if [[ -d /etc/nginx/sites-available ]]; then
    install -m 0644 "$RENDERED" /etc/nginx/sites-available/embedded_health
    ln -sfn /etc/nginx/sites-available/embedded_health /etc/nginx/sites-enabled/embedded_health
    SITE=/etc/nginx/sites-available/embedded_health
  else
    install -m 0644 "$RENDERED" /etc/nginx/conf.d/embedded_health.conf
    SITE=/etc/nginx/conf.d/embedded_health.conf
  fi
  rm -f "$RENDERED"
  info "site: $SITE"

  # A pre-existing default server on the same address:port would shadow ours.
  if ! nginx -t 2>&1 | grep -q 'test is successful'; then
    nginx -t || true
    warn "nginx rejected the configuration; the site file is at $SITE"
    warn "the app itself is running -- fix nginx and run: nginx -t && systemctl reload nginx"
  else
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    info "reloaded"
  fi

  step "verifying through nginx"
  if curl -fsS --max-time 5 "http://$LISTEN/embedded_health/api/healthz" >/dev/null; then
    info "GET http://$LISTEN/embedded_health/ -> ok"
    # Prove the write path works end to end, then clean the probe up.
    if curl -fsS --max-time 5 -X POST "http://$LISTEN/embedded_health/api/heartbeat" \
         -H 'Content-Type: application/json' \
         -d '{"device_id":"deploy-selftest","hostname":"deploy-selftest","ip":"0.0.0.0","model":"deployment probe"}' >/dev/null; then
      curl -fsS --max-time 5 -X POST \
        "http://$LISTEN/embedded_health/api/nodes/deploy-selftest/forget" >/dev/null || true
      info "heartbeat write path -> ok"
    else
      warn "the heartbeat endpoint did not accept a test POST"
    fi
  else
    warn "could not reach the service through nginx at http://$LISTEN/embedded_health/"
    warn "check for another server block already bound to $LISTEN:80"
  fi
fi

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
BEAT_URL="http://$SERVER_NAME/embedded_health/api/heartbeat"
cat <<EOF

${C_OK}Deployment complete.${C_OFF}

  Dashboard     http://$SERVER_NAME/embedded_health/
  Bound to      $LISTEN ($IFACE) only
  App           127.0.0.1:$PORT, gunicorn under systemd
  Code          $PREFIX
  Config        $CONF_DIR/server.env
  State         /var/lib/embedded-health/nodes.db

  Autostart and self-healing are on: 'systemctl enable' plus Restart=always,
  so the service returns after a crash and after a reboot.

  ${C_DIM}systemctl status $SVC_NAME
  journalctl -u $SVC_NAME -f
  sudo $PREFIX/deploy/deploy.sh --repo <url>   # upgrade in place${C_OFF}

On each embedded node:

  git clone <repo> && cd embedded_health
  sudo ./agent/install-agent.sh --url $BEAT_URL --tags lab-b

The node appears on the dashboard within one heartbeat interval.
EOF
