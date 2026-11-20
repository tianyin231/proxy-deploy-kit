#!/usr/bin/env bash
# Harden an Ubuntu/Debian transit host for any sing-box instance.
# Automatically discovers certificate_path, key_path, and listen_port from JSON configs!
# Default is dry-run: prints every action. Pass --apply to actually change the system.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: harden-ubuntu.sh [options]

  --apply              Apply changes (default is dry-run)
  --instance NAME      Instance slug (default: relay -> /etc/sing-box-relay/config.json)
  --config PATH        Config or key file to chmod 600 (repeatable; also parsed for TLS cert/key & ports)
  --sysctl-dest PATH   sysctl.d destination (default: /etc/sysctl.d/90-proxy-bbr.conf)
  --backup-dir PATH    Backup existing configs before chmod (default: /var/backups/proxy)
  --skip-ufw           Do not touch UFW
  --skip-bbr           Do not write sysctl / load BBR
  --ssh-port PORT      Extra SSH port to allow (auto-detected if omitted)
  --proxy-port PORT    Proxy listen port to allow in UFW (auto-detected from config or 443)
  -h, --help           Show this help
USAGE
}

APPLY=0
SKIP_UFW=0
SKIP_BBR=0
INSTANCE="relay"
SYSCTL_DEST=/etc/sysctl.d/90-proxy-bbr.conf
BACKUP_DIR=/var/backups/proxy
SSH_PORT_OVERRIDE=""
PROXY_PORTS=()
CONFIG_PATHS=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSCTL_SRC="$REPO_ROOT/server/90-proxy-bbr.conf"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --skip-ufw) SKIP_UFW=1; shift ;;
    --skip-bbr) SKIP_BBR=1; shift ;;
    --instance)
      [[ $# -ge 2 ]] || { echo "error: --instance requires a name" >&2; exit 2; }
      INSTANCE="$2"; shift 2 ;;
    --config)
      [[ $# -ge 2 ]] || { echo "error: --config requires a path" >&2; exit 2; }
      CONFIG_PATHS+=("$2"); shift 2 ;;
    --sysctl-dest)
      [[ $# -ge 2 ]] || { echo "error: --sysctl-dest requires a path" >&2; exit 2; }
      SYSCTL_DEST="$2"; shift 2 ;;
    --backup-dir)
      [[ $# -ge 2 ]] || { echo "error: --backup-dir requires a path" >&2; exit 2; }
      BACKUP_DIR="$2"; shift 2 ;;
    --ssh-port)
      [[ $# -ge 2 ]] || { echo "error: --ssh-port requires a port" >&2; exit 2; }
      SSH_PORT_OVERRIDE="$2"; shift 2 ;;
    --proxy-port)
      [[ $# -ge 2 ]] || { echo "error: --proxy-port requires a port" >&2; exit 2; }
      PROXY_PORTS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ${#CONFIG_PATHS[@]} -eq 0 ]]; then
  DEFAULT_DIR="/etc/sing-box-${INSTANCE}"
  for p in "$DEFAULT_DIR/config.json" "$DEFAULT_DIR/hy2.crt" "$DEFAULT_DIR/hy2.key"; do
    CONFIG_PATHS+=("$p")
  done
fi

# Dynamically inspect JSON config files to discover exact certificate_path, key_path, and listen_port
if command -v python3 >/dev/null 2>&1; then
  for cfg in "${CONFIG_PATHS[@]}"; do
    if [[ -f "$cfg" && "$cfg" == *.json ]]; then
      while IFS='=' read -r kind val; do
        if [[ "$kind" == "FILE" && -n "$val" ]]; then
          CONFIG_PATHS+=("$val")
        elif [[ "$kind" == "PORT" && -n "$val" ]]; then
          PROXY_PORTS+=("$val")
        fi
      done < <(python3 - "$cfg" <<'PY' 2>/dev/null || true
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for ib in data.get("inbounds", []):
    lp = ib.get("listen_port")
    if isinstance(lp, int):
        print(f"PORT={lp}")
    tls = ib.get("tls") or {}
    for k in ("certificate_path", "key_path"):
        if isinstance(tls.get(k), str) and tls[k]:
            print(f"FILE={tls[k]}")
PY
      )
    fi
  done
fi

if [[ ${#PROXY_PORTS[@]} -eq 0 ]]; then
  PROXY_PORTS=(443)
fi
mapfile -t PROXY_PORTS < <(printf '%s\n' "${PROXY_PORTS[@]}" | awk 'NF && !seen[$0]++')
mapfile -t CONFIG_PATHS < <(printf '%s\n' "${CONFIG_PATHS[@]}" | awk 'NF && !seen[$0]++')

MODE=dry-run
if [[ "$APPLY" -eq 1 ]]; then MODE=apply; fi
echo "[harden-ubuntu] mode=$MODE instance=$INSTANCE"

if [[ "$APPLY" -eq 1 && "$(id -u)" -ne 0 && "${ALLOW_NONROOT_HARDEN:-0}" -ne 1 ]]; then
  echo "error: --apply must be run as root (try sudo)" >&2
  exit 1
fi

run() {
  if [[ "$APPLY" -eq 1 ]]; then
    printf '+ '; printf '%q ' "$@"; echo
    "$@"
  else
    printf '[dry-run] '; printf '%q ' "$@"; echo
  fi
}

detect_ssh_ports() {
  local ports=() p
  if [[ -n "$SSH_PORT_OVERRIDE" ]]; then
    echo "$SSH_PORT_OVERRIDE"
    return 0
  fi
  if [[ -r /etc/ssh/sshd_config ]]; then
    while read -r p; do
      if [[ -n "$p" ]]; then ports+=("$p"); fi
    done < <(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2}' /etc/ssh/sshd_config 2>/dev/null || true)
  fi
  if command -v ss >/dev/null 2>&1; then
    while read -r p; do
      if [[ -n "$p" ]]; then ports+=("$p"); fi
    done < <(ss -lntp 2>/dev/null | awk '/sshd/{print $4}' | sed -n 's/.*:\([0-9]*\)$/\1/p' || true)
  fi
  if [[ ${#ports[@]} -eq 0 ]]; then
    ports+=(22)
  fi
  printf '%s\n' "${ports[@]}" | awk 'NF && !seen[$0]++'
}

# ---------- BBR ----------
if [[ "$SKIP_BBR" -eq 0 ]]; then
  echo
  echo "==> BBR + fq"
  if [[ ! -f "$SYSCTL_SRC" ]]; then
    echo "error: missing sysctl template: $SYSCTL_SRC" >&2
    exit 1
  fi
  run mkdir -p "$(dirname "$SYSCTL_DEST")"
  if [[ "$APPLY" -eq 1 ]]; then
    install -m 0644 "$SYSCTL_SRC" "$SYSCTL_DEST"
    echo "+ install -m 0644 $SYSCTL_SRC $SYSCTL_DEST"
    sysctl --system >/tmp/harden-sysctl.out 2>&1 || {
      echo "warning: sysctl --system returned $?; see /tmp/harden-sysctl.out" >&2
    }
  else
    echo "[dry-run] install -m 0644 $SYSCTL_SRC $SYSCTL_DEST"
    echo "[dry-run] sysctl --system"
  fi
else
  echo "==> BBR skipped"
fi

# ---------- UFW ----------
if [[ "$SKIP_UFW" -eq 0 ]]; then
  echo
  echo "==> UFW"
  if ! command -v ufw >/dev/null 2>&1; then
    echo "UFW is not installed. On Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y ufw"
    if [[ "$APPLY" -eq 1 ]]; then
      echo "error: UFW missing; install it or pass --skip-ufw" >&2
      exit 1
    fi
  else
    mapfile -t SSH_PORTS < <(detect_ssh_ports)
    echo "SSH ports to allow: ${SSH_PORTS[*]}"
    echo "Proxy ports to allow: ${PROXY_PORTS[*]}"
    run ufw default deny incoming
    run ufw default allow outgoing
    for p in "${SSH_PORTS[@]}"; do
      run ufw allow "${p}/tcp"
    done
    for pp in "${PROXY_PORTS[@]}"; do
      run ufw allow "${pp}/tcp"
      run ufw allow "${pp}/udp"
    done
    if [[ "$APPLY" -eq 1 ]]; then
      ufw --force enable
      ufw status verbose
    else
      echo "[dry-run] ufw --force enable"
    fi
  fi
else
  echo "==> UFW skipped"
fi

# ---------- permissions + backup ----------
echo
echo "==> config/key permissions (0600) and backup"
run mkdir -p "$BACKUP_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
found=0
for p in "${CONFIG_PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    found=1
    backup_name="$BACKUP_DIR/$(basename "$p").${stamp}.bak"
    run cp -a "$p" "$backup_name"
    run chmod 600 "$p"
  else
    echo "skip (not present): $p"
  fi
done
if [[ "$found" -eq 0 ]]; then
  echo "note: no config/key files found yet; chmod will apply after you install them"
fi

echo
if [[ "$APPLY" -eq 1 ]]; then
  echo "[harden-ubuntu] done"
else
  echo "[harden-ubuntu] dry-run only; re-run with --apply to make changes"
fi
