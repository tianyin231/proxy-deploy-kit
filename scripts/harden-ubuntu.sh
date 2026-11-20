#!/usr/bin/env bash
# Harden an Ubuntu/Debian transit host for the sing-box proxy kit.
# Default is dry-run: prints every action. Pass --apply to actually change the system.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: harden-ubuntu.sh [options]

  --apply                Apply changes (default is dry-run)
  --config PATH          Config or key file to chmod 600 (repeatable).
                         If omitted, these paths are used when they exist:
                           /etc/sing-box-jp/config.json
                           /etc/sing-box-jp/tls-cert.pem
                           /etc/sing-box-jp/tls-key.pem
  --sysctl-dest PATH     sysctl.d destination
                         (default: /etc/sysctl.d/90-proxy-bbr.conf)
  --backup-dir PATH      Backup existing configs before chmod
                         (default: /var/backups/proxy)
  --skip-ufw             Do not touch UFW
  --skip-bbr             Do not write sysctl / load BBR
  --ssh-port PORT        Extra SSH port to allow (auto-detected if omitted)
  -h, --help             Show this help

This script only opens 22/tcp (plus any detected SSH port), 443/tcp and
443/udp. It never deletes existing allow rules. Run it before enabling
UFW for the first time so SSH is not locked out.
USAGE
}

APPLY=0
SKIP_UFW=0
SKIP_BBR=0
SYSCTL_DEST=/etc/sysctl.d/90-proxy-bbr.conf
BACKUP_DIR=/var/backups/proxy
SSH_PORT_OVERRIDE=""
CONFIG_PATHS=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSCTL_SRC="$REPO_ROOT/server/90-proxy-bbr.conf"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --skip-ufw) SKIP_UFW=1; shift ;;
    --skip-bbr) SKIP_BBR=1; shift ;;
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
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ${#CONFIG_PATHS[@]} -eq 0 ]]; then
  for p in /etc/sing-box-jp/config.json /etc/sing-box-jp/tls-cert.pem /etc/sing-box-jp/tls-key.pem; do
    CONFIG_PATHS+=("$p")
  done
fi

MODE=dry-run
[[ "$APPLY" -eq 1 ]] && MODE=apply
echo "[harden-ubuntu] mode=$MODE"

if [[ "$APPLY" -eq 1 && "$(id -u)" -ne 0 ]]; then
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

# Detect SSH listen ports so we never enable UFW without an allow rule.
detect_ssh_ports() {
  local ports=() p
  if [[ -n "$SSH_PORT_OVERRIDE" ]]; then
    echo "$SSH_PORT_OVERRIDE"
    return 0
  fi
  if [[ -r /etc/ssh/sshd_config ]]; then
    while read -r p; do
      [[ -n "$p" ]] && ports+=("$p")
    done < <(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2}' /etc/ssh/sshd_config 2>/dev/null || true)
  fi
  if command -v ss >/dev/null 2>&1; then
    while read -r p; do
      [[ -n "$p" ]] && ports+=("$p")
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
    sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control
  else
    echo "[dry-run] install -m 0644 $SYSCTL_SRC $SYSCTL_DEST"
    echo "[dry-run] sysctl --system"
    echo "[dry-run] would expect: net.core.default_qdisc=fq  net.ipv4.tcp_congestion_control=bbr"
  fi
else
  echo "==> BBR skipped"
fi

# ---------- UFW ----------
if [[ "$SKIP_UFW" -eq 0 ]]; then
  echo
  echo "==> UFW"
  if ! command -v ufw >/dev/null 2>&1; then
    echo "UFW is not installed. On Ubuntu/Debian:"
    echo "  sudo apt-get update && sudo apt-get install -y ufw"
    if [[ "$APPLY" -eq 1 ]]; then
      echo "error: UFW missing; install it or pass --skip-ufw" >&2
      exit 1
    fi
  else
    mapfile -t SSH_PORTS < <(detect_ssh_ports)
    echo "SSH ports to allow: ${SSH_PORTS[*]}"
    run ufw default deny incoming
    run ufw default allow outgoing
    for p in "${SSH_PORTS[@]}"; do
      run ufw allow "${p}/tcp"
    done
    run ufw allow 443/tcp
    run ufw allow 443/udp
    if [[ "$APPLY" -eq 1 ]]; then
      # --force skips the interactive "proceed with operation?" prompt
      ufw --force enable
      ufw status verbose
    else
      echo "[dry-run] ufw --force enable"
      echo "[dry-run] ufw status verbose"
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
    if [[ "$APPLY" -eq 1 ]]; then
      ls -l "$p" "$backup_name"
    fi
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
