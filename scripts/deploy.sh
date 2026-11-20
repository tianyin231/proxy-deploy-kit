#!/usr/bin/env bash
# Install or upgrade the official sing-box binary and this kit's systemd unit
# on Ubuntu/Debian. Default is dry-run. Pass --apply to write files and start
# the service. The script never pipes curl into sh, and it does not print
# config contents or secret values.
set -euo pipefail

DEFAULT_VERSION="1.14.4"
GITHUB_REPO="SagerNet/sing-box"

usage() {
  cat <<USAGE
Usage: deploy.sh --config PATH [options]

Install or upgrade sing-box from the official GitHub release, then install
this kit's config and systemd unit. Default is dry-run (no system changes).

  --config PATH          Filled sing-box JSON (required). Unfilled
                         <PLACEHOLDER> values are rejected. A file that
                         only parses as JSON is not yet a usable config.
  --instance NAME        Instance slug (default: relay). Sets unit
                         sing-box-NAME and /etc/sing-box-NAME/ unless
                         --unit-name or --config-dest is given
  --apply                Write files, install the binary, and start the unit
  --version VER          Official sing-box version (default: ${DEFAULT_VERSION})
  --allow-prerelease     Allow a pre-release tag
  --dest-root DIR        Install prefix (default: /). Use only for tests;
                         when this is not /, host systemd/UFW are not touched
  --bin-dir DIR          Binary directory (default: DEST_ROOT/usr/local/bin)
  --config-dest PATH     Installed config path
                         (default: DEST_ROOT/etc/sing-box-<instance>/config.json)
  --unit-name NAME       systemd unit name without .service
                         (default: sing-box-<instance>)
  --unit-src PATH        Unit template (default: server/sing-box.service.template)
  --backup-dir DIR       Backup directory (default: DEST_ROOT/var/backups/proxy)
  --download-dir DIR     Temporary download dir (created with mktemp by default)
  --skip-download        Do not download; use --sing-box-bin or PATH
  --sing-box-bin PATH    Existing sing-box binary to install or to run check
  --expected-sha256 HEX  Override the GitHub release asset digest
  --harden               After a successful apply, run harden-ubuntu.sh
                         (optional; off by default). Refused when dest-root
                         is not / so the host firewall is not changed by tests
  --ssh-port PORT        Passed through to harden-ubuntu.sh
  --skip-os-check        Do not require Ubuntu/Debian
  --skip-port-check      Do not inspect host sockets for listen-port conflicts
  --force-port-check     Inspect sockets even when --dest-root is not /
  --force-systemd        Call systemctl even when dest-root is not / (tests)
  --allow-nonroot        Allow --apply without root (tests with --dest-root)
  -h, --help             Show this help

This script only manages the unit and paths for the chosen --instance.
It will not overwrite a different systemd unit, and it will refuse to bind
ports already used by an unrelated process.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APPLY=0
CONFIG_SRC=""
INSTANCE="relay"
VERSION="$DEFAULT_VERSION"
ALLOW_PRERELEASE=0
DEST_ROOT="/"
BIN_DIR=""
CONFIG_DEST=""
UNIT_NAME=""
UNIT_SRC="$REPO_ROOT/server/sing-box.service.template"
BACKUP_DIR=""
DOWNLOAD_DIR=""
SKIP_DOWNLOAD=0
SING_BOX_BIN=""
EXPECTED_SHA256=""
HARDEN=0
SSH_PORT=""
SKIP_OS_CHECK=0
SKIP_PORT_CHECK=0
FORCE_PORT_CHECK=0
FORCE_SYSTEMD=0
ALLOW_NONROOT=0

log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
err() { printf 'error: %s\n' "$*" >&2; }
die() { err "$1"; exit "${2:-1}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || die "--config requires a path" 2
      CONFIG_SRC="$2"; shift 2 ;;
    --instance)
      [[ $# -ge 2 ]] || die "--instance requires a name" 2
      INSTANCE="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value" 2
      VERSION="$2"; shift 2 ;;
    --allow-prerelease) ALLOW_PRERELEASE=1; shift ;;
    --dest-root)
      [[ $# -ge 2 ]] || die "--dest-root requires a path" 2
      DEST_ROOT="$2"; shift 2 ;;
    --bin-dir)
      [[ $# -ge 2 ]] || die "--bin-dir requires a path" 2
      BIN_DIR="$2"; shift 2 ;;
    --config-dest)
      [[ $# -ge 2 ]] || die "--config-dest requires a path" 2
      CONFIG_DEST="$2"; shift 2 ;;
    --unit-name)
      [[ $# -ge 2 ]] || die "--unit-name requires a name" 2
      UNIT_NAME="$2"; shift 2 ;;
    --unit-src)
      [[ $# -ge 2 ]] || die "--unit-src requires a path" 2
      UNIT_SRC="$2"; shift 2 ;;
    --backup-dir)
      [[ $# -ge 2 ]] || die "--backup-dir requires a path" 2
      BACKUP_DIR="$2"; shift 2 ;;
    --download-dir)
      [[ $# -ge 2 ]] || die "--download-dir requires a path" 2
      DOWNLOAD_DIR="$2"; shift 2 ;;
    --skip-download) SKIP_DOWNLOAD=1; shift ;;
    --sing-box-bin)
      [[ $# -ge 2 ]] || die "--sing-box-bin requires a path" 2
      SING_BOX_BIN="$2"; shift 2 ;;
    --expected-sha256)
      [[ $# -ge 2 ]] || die "--expected-sha256 requires a hex digest" 2
      EXPECTED_SHA256="$2"; shift 2 ;;
    --harden) HARDEN=1; shift ;;
    --ssh-port)
      [[ $# -ge 2 ]] || die "--ssh-port requires a port" 2
      SSH_PORT="$2"; shift 2 ;;
    --skip-os-check) SKIP_OS_CHECK=1; shift ;;
    --skip-port-check) SKIP_PORT_CHECK=1; shift ;;
    --force-port-check) FORCE_PORT_CHECK=1; shift ;;
    --force-systemd) FORCE_SYSTEMD=1; shift ;;
    --allow-nonroot) ALLOW_NONROOT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

if [[ -z "$CONFIG_SRC" ]]; then
  err "--config is required"
  usage >&2
  exit 2
fi

# Normalize paths. DEST_ROOT=/ means a real host install.
DEST_ROOT="$(realpath -m "$DEST_ROOT")"
[[ "$DEST_ROOT" == "/" ]] || DEST_ROOT="${DEST_ROOT%/}"
if ! [[ "$INSTANCE" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]; then
  die "invalid --instance '$INSTANCE': use a lowercase slug (letters, digits, hyphens)"
fi
UNIT_NAME="${UNIT_NAME:-sing-box-${INSTANCE}}"
UNIT_NAME="${UNIT_NAME%.service}"
[[ -n "$BIN_DIR" ]] || BIN_DIR="$DEST_ROOT/usr/local/bin"
[[ -n "$CONFIG_DEST" ]] || CONFIG_DEST="$DEST_ROOT/etc/sing-box-${INSTANCE}/config.json"
CONFIG_DIR="$(dirname "$CONFIG_DEST")"
UNIT_DEST="$DEST_ROOT/etc/systemd/system/${UNIT_NAME}.service"
BIN_DEST="$BIN_DIR/sing-box"
[[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$DEST_ROOT/var/backups/proxy"

PREFIX=""
if [[ "$DEST_ROOT" != "/" ]]; then PREFIX="$DEST_ROOT"; fi
RUNTIME_CONFIG_PATH="${CONFIG_DEST#"$PREFIX"}"
if [[ -z "$RUNTIME_CONFIG_PATH" || "$RUNTIME_CONFIG_PATH" == "$CONFIG_DEST" && "$DEST_ROOT" != "/" ]]; then
  RUNTIME_CONFIG_PATH="/etc/sing-box-${INSTANCE}/config.json"
fi
[[ "$RUNTIME_CONFIG_PATH" == /* ]] || RUNTIME_CONFIG_PATH="/$RUNTIME_CONFIG_PATH"
RUNTIME_BIN_PATH="${BIN_DEST#"$PREFIX"}"
if [[ -z "$RUNTIME_BIN_PATH" ]]; then RUNTIME_BIN_PATH="/usr/local/bin/sing-box"; fi
[[ "$RUNTIME_BIN_PATH" == /* ]] || RUNTIME_BIN_PATH="/$RUNTIME_BIN_PATH"

VERSION="${VERSION#v}"
TAG="v$VERSION"

if [[ "$DEST_ROOT" == "/" ]]; then
  USE_SYSTEMD=1
else
  USE_SYSTEMD=0
fi
[[ "$FORCE_SYSTEMD" -eq 1 ]] && USE_SYSTEMD=1

MODE=dry-run
[[ "$APPLY" -eq 1 ]] && MODE=apply
log "[deploy] mode=$MODE dest-root=$DEST_ROOT unit=$UNIT_NAME version=$TAG"

planned() {
  if [[ "$APPLY" -eq 1 ]]; then
    printf '  plan: %s\n' "$*"
  else
    printf '  [dry-run] %s\n' "$*"
  fi
}

# Work directory is 0700 and always removed, so config copies are not left behind.
WORK_DIR=""
BACKUP_STAMP=""
BACKUP_PATH=""
NEED_ROLLBACK=0
WROTE_CONFIG=0
WROTE_UNIT=0
WROTE_BINARY=0
DID_DAEMON_RELOAD=0
DID_START=0
HAD_CONFIG=0
HAD_UNIT=0
HAD_BINARY=0
WROTE_CERTS=0
HAD_CERTS=0
ORIG_ACTIVE="missing"
ORIG_ENABLED="missing"
ROLLBACK_NOTES=()

cleanup() {
  local rc=$?
  if [[ "$rc" -ne 0 && "$APPLY" -eq 1 && "$NEED_ROLLBACK" -eq 1 ]]; then
    # Rollback must not be skipped if a later command in this trap fails.
    rollback || true
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  exit "$rc"
}
trap cleanup EXIT

record() { ROLLBACK_NOTES+=("$1"); }

rollback() {
  log "[deploy] apply failed; rolling back anything this run changed"
  local ok=1
  if [[ "$WROTE_CONFIG" -eq 1 ]]; then
    if [[ "$HAD_CONFIG" -eq 1 && -f "$BACKUP_PATH/config.json" ]]; then
      if cp -a -- "$BACKUP_PATH/config.json" "$CONFIG_DEST" && chmod 600 "$CONFIG_DEST"; then
        record "restored $CONFIG_DEST from backup"
      else
        record "FAILED to restore $CONFIG_DEST"
        ok=0
      fi
    else
      if rm -f -- "$CONFIG_DEST"; then
        record "removed new $CONFIG_DEST (no previous config)"
      else
        record "FAILED to remove new $CONFIG_DEST"
        ok=0
      fi
    fi
  else
    record "config was not replaced; no config rollback needed"
  fi

  if [[ "$WROTE_CERTS" -eq 1 ]]; then
    if [[ -d "$BACKUP_PATH/certs" ]]; then
      local cert
      for cert in "$BACKUP_PATH/certs"/*; do
        [[ -f "$cert" ]] || continue
        if cp -a -- "$cert" "$CONFIG_DIR/$(basename "$cert")"; then
          record "restored $CONFIG_DIR/$(basename "$cert") from backup"
        else
          record "FAILED to restore $CONFIG_DIR/$(basename "$cert")"
          ok=0
        fi
      done
    fi
    if [[ -f "$BACKUP_PATH/certs-created.txt" ]]; then
      local created
      while IFS= read -r created; do
        [[ -n "$created" ]] || continue
        if rm -f -- "$created"; then
          record "removed new cert $created (no previous copy)"
        fi
      done < "$BACKUP_PATH/certs-created.txt"
    fi
  fi

  if [[ "$WROTE_UNIT" -eq 1 ]]; then
    if [[ "$HAD_UNIT" -eq 1 && -f "$BACKUP_PATH/${UNIT_NAME}.service" ]]; then
      if cp -a -- "$BACKUP_PATH/${UNIT_NAME}.service" "$UNIT_DEST"; then
        record "restored $UNIT_DEST from backup"
      else
        record "FAILED to restore $UNIT_DEST"
        ok=0
      fi
    else
      if rm -f -- "$UNIT_DEST"; then
        record "removed new $UNIT_DEST (no previous unit)"
      else
        record "FAILED to remove new $UNIT_DEST"
        ok=0
      fi
    fi
  else
    record "unit was not replaced; no unit rollback needed"
  fi

  if [[ "$WROTE_BINARY" -eq 1 ]]; then
    if [[ "$HAD_BINARY" -eq 1 && -f "$BACKUP_PATH/sing-box" ]]; then
      if cp -a -- "$BACKUP_PATH/sing-box" "$BIN_DEST"; then
        record "restored $BIN_DEST from backup"
      else
        record "FAILED to restore $BIN_DEST"
        ok=0
      fi
    else
      if rm -f -- "$BIN_DEST"; then
        record "removed new $BIN_DEST (no previous binary)"
      else
        record "FAILED to remove new $BIN_DEST"
        ok=0
      fi
    fi
  else
    record "binary was not replaced; no binary rollback needed"
  fi

  if [[ "$USE_SYSTEMD" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
    if [[ "$DID_DAEMON_RELOAD" -eq 1 || "$WROTE_UNIT" -eq 1 ]]; then
      if systemctl daemon-reload; then
        record "systemctl daemon-reload after rollback"
      else
        record "FAILED systemctl daemon-reload after rollback"
        ok=0
      fi
    fi
    case "$ORIG_ACTIVE" in
      active)
        if systemctl start "${UNIT_NAME}.service"; then
          record "restarted ${UNIT_NAME}.service (was active)"
        else
          record "FAILED to restart ${UNIT_NAME}.service (was active)"
          ok=0
        fi
        ;;
      *)
        if [[ "$DID_START" -eq 1 || "$ORIG_ACTIVE" == "inactive" || "$ORIG_ACTIVE" == "failed" ]]; then
          if systemctl stop "${UNIT_NAME}.service" 2>/dev/null || true; then
            record "stopped ${UNIT_NAME}.service (was ${ORIG_ACTIVE})"
          fi
        fi
        ;;
    esac
    if [[ "$ORIG_ENABLED" == "enabled" ]]; then
      systemctl enable "${UNIT_NAME}.service" >/dev/null 2>&1 || true
      record "left ${UNIT_NAME}.service enabled (was enabled)"
    elif [[ "$ORIG_ENABLED" == "disabled" || "$ORIG_ENABLED" == "missing" ]]; then
      if [[ "$ORIG_ENABLED" == "missing" ]]; then
        systemctl disable "${UNIT_NAME}.service" >/dev/null 2>&1 || true
        record "disabled ${UNIT_NAME}.service (was missing)"
      fi
    fi
  else
    record "systemd was not used; no service-state rollback"
  fi

  local note
  for note in "${ROLLBACK_NOTES[@]}"; do
    log "  rollback: $note"
  done
  if [[ "$ok" -eq 1 ]]; then
    log "[deploy] rollback finished; previous files and service state were restored"
  else
    err "rollback completed with failures; inspect $BACKUP_PATH and the notes above"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# ---------- required arguments and config checks ----------
CONFIG_SRC="$(realpath -m "$CONFIG_SRC")"
[[ -f "$CONFIG_SRC" ]] || die "config not found: $CONFIG_SRC"
[[ -r "$CONFIG_SRC" ]] || die "config is not readable: $CONFIG_SRC"
[[ -f "$UNIT_SRC" ]] || die "unit template not found: $UNIT_SRC"

require_cmd python3

# Parse JSON and reject leftovers. Print only placeholder names or the
# parser error location, never the file body.
config_scan="$(python3 - "$CONFIG_SRC" <<'PY'
import json, re, sys
path = sys.argv[1]
try:
    raw = open(path, encoding="utf-8").read()
except OSError as e:
    print("READ_ERROR:" + str(e))
    sys.exit(1)
try:
    json.loads(raw)
except json.JSONDecodeError as e:
    print("JSON_ERROR:line {0} col {1}: {2}".format(e.lineno, e.colno, e.msg))
    sys.exit(1)
placeholders = sorted(set(re.findall(r"<[A-Z][A-Z0-9_]*>", raw)))
if placeholders:
    for p in placeholders:
        print("PLACEHOLDER:" + p)
    sys.exit(1)
print("JSON_OK")
PY
)" || true

if printf '%s\n' "$config_scan" | grep -q '^READ_ERROR:'; then
  die "cannot read config ($(printf '%s\n' "$config_scan" | sed -n 's/^READ_ERROR://p'))"
fi
if printf '%s\n' "$config_scan" | grep -q '^JSON_ERROR:'; then
  die "config is not valid JSON ($(printf '%s\n' "$config_scan" | sed -n 's/^JSON_ERROR://p')). A broken file is not deployable."
fi
if printf '%s\n' "$config_scan" | grep -q '^PLACEHOLDER:'; then
  err "config still contains unfilled placeholders (a parseable template is not a working config):"
  printf '%s\n' "$config_scan" | sed -n 's/^PLACEHOLDER:/  /p' >&2
  exit 1
fi
if ! printf '%s\n' "$config_scan" | grep -qx 'JSON_OK'; then
  die "internal error while checking the config"
fi
log "config JSON parsed and has no <PLACEHOLDER> tokens"
log "note: JSON parsing is not the same as sing-box accepting the config; sing-box check still has to pass"

# ---------- OS / privileges / dependencies ----------
if [[ "$SKIP_OS_CHECK" -eq 0 ]]; then
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) log "os: ${PRETTY_NAME:-$ID}" ;;
      *)
        msg="this script targets Ubuntu/Debian (got ${ID:-unknown})"
        if [[ "$APPLY" -eq 1 ]]; then
          die "$msg; pass --skip-os-check if you understand the risk"
        else
          warn "$msg"
        fi
        ;;
    esac
  else
    [[ "$APPLY" -eq 1 ]] && die "cannot read /etc/os-release; pass --skip-os-check to override"
    warn "cannot read /etc/os-release"
  fi
fi

if [[ "$APPLY" -eq 1 && "$(id -u)" -ne 0 && "$ALLOW_NONROOT" -eq 0 ]]; then
  die "--apply must be run as root (try sudo), or pass --allow-nonroot for dest-root tests"
fi

require_cmd tar
require_cmd sha256sum
require_cmd install
require_cmd curl
require_cmd mktemp
if [[ "$SKIP_DOWNLOAD" -eq 0 ]]; then
  require_cmd uname
fi
if [[ "$USE_SYSTEMD" -eq 1 && "$APPLY" -eq 1 ]]; then
  require_cmd systemctl
fi

# ---------- architecture and release asset ----------
detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    armv6l) echo armv6 ;;
    i386|i686) echo 386 ;;
    *) die "unsupported architecture: $m" ;;
  esac
}

ARCH="$(detect_arch)"
ASSET="sing-box-${VERSION}-linux-${ARCH}.tar.gz"
ASSET_URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/${ASSET}"
log "architecture: $ARCH  asset: $ASSET"

fetch_release_meta() {
  python3 - "$GITHUB_REPO" "$TAG" "$ASSET" "$ALLOW_PRERELEASE" <<'PY'
import json, sys, urllib.request
repo, tag, asset, allow_pre = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
url = "https://api.github.com/repos/{0}/releases/tags/{1}".format(repo, tag)
req = urllib.request.Request(
    url,
    headers={
        "User-Agent": "proxy-deploy-kit",
        "Accept": "application/vnd.github+json",
    },
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
except Exception as e:
    print("META_ERROR:" + str(e))
    sys.exit(1)
if data.get("draft"):
    print("META_ERROR:release {0} is a draft".format(tag))
    sys.exit(1)
if data.get("prerelease") and not allow_pre:
    print("META_ERROR:{0} is a pre-release; pass --allow-prerelease to use it".format(tag))
    sys.exit(1)
for item in data.get("assets") or []:
    if item.get("name") == asset:
        digest = item.get("digest") or ""
        download = item.get("browser_download_url") or ""
        size = item.get("size") or 0
        print("NAME=" + item["name"])
        print("SIZE=" + str(size))
        print("DIGEST=" + digest)
        print("URL=" + download)
        sys.exit(0)
print("META_ERROR:asset {0} not found in {1}".format(asset, tag))
sys.exit(1)
PY
}

RESOLVED_URL="$ASSET_URL"
RESOLVED_DIGEST=""
RESOLVED_SIZE=""

if [[ "$SKIP_DOWNLOAD" -eq 0 ]]; then
  if [[ -n "$EXPECTED_SHA256" ]]; then
    RESOLVED_DIGEST="sha256:${EXPECTED_SHA256#sha256:}"
    log "using caller-supplied sha256 digest"
  else
    meta="$(fetch_release_meta)" || true
    if printf '%s\n' "$meta" | grep -q '^META_ERROR:'; then
      die "could not resolve official release $(printf '%s\n' "$meta" | sed -n 's/^META_ERROR://p')"
    fi
    RESOLVED_URL="$(printf '%s\n' "$meta" | sed -n 's/^URL=//p')"
    RESOLVED_DIGEST="$(printf '%s\n' "$meta" | sed -n 's/^DIGEST=//p')"
    RESOLVED_SIZE="$(printf '%s\n' "$meta" | sed -n 's/^SIZE=//p')"
  fi
  if [[ -z "$RESOLVED_URL" ]]; then
    die "official download URL was empty"
  fi
  if [[ -z "$RESOLVED_DIGEST" || "$RESOLVED_DIGEST" != sha256:* ]]; then
    die "official release did not publish a sha256 digest for $ASSET; refusing to download unverified"
  fi
  log "official asset: $RESOLVED_URL"
  log "official sha256: ${RESOLVED_DIGEST#sha256:}  size: ${RESOLVED_SIZE:-unknown}"
  planned "download $ASSET, verify sha256, extract sing-box, install to $BIN_DEST"
else
  log "skipping download"
  if [[ -n "$SING_BOX_BIN" ]]; then
    [[ -x "$SING_BOX_BIN" ]] || die "sing-box binary not executable: $SING_BOX_BIN"
    planned "use existing binary $SING_BOX_BIN"
  else
    if command -v sing-box >/dev/null 2>&1; then
      SING_BOX_BIN="$(command -v sing-box)"
      planned "use sing-box from PATH: $SING_BOX_BIN"
    elif [[ -x "$BIN_DEST" ]]; then
      SING_BOX_BIN="$BIN_DEST"
      planned "use already-installed $BIN_DEST"
    else
      die "--skip-download requires --sing-box-bin or an existing sing-box on PATH"
    fi
  fi
fi

# ---------- port and service conflict checks ----------
listen_ports="$(python3 - "$CONFIG_SRC" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
ports = []
for inbound in cfg.get("inbounds") or []:
    port = inbound.get("listen_port")
    proto = inbound.get("type")
    if isinstance(port, int):
        kind = "udp" if proto == "hysteria2" else "tcp"
        ports.append("{0}/{1}".format(port, kind))
for item in ports:
    print(item)
PY
)"

if [[ "$SKIP_PORT_CHECK" -eq 0 && ( "$DEST_ROOT" == "/" || "$FORCE_PORT_CHECK" -eq 1 ) ]]; then
  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r spec; do
      [[ -n "$spec" ]] || continue
      port="${spec%/*}"
      proto="${spec#*/}"
      # -H is not portable; parse without depending on process names when ss is limited.
      if [[ "$proto" == "udp" ]]; then
        holders="$(ss -lunp 2>/dev/null | awk -v port="$port" '$4 ~ (":" port "$") || $4 ~ (":" port "]$") {print}' || true)"
      else
        holders="$(ss -ltnp 2>/dev/null | awk -v port="$port" '$4 ~ (":" port "$") || $4 ~ (":" port "]$") {print}' || true)"
      fi
      if [[ -n "$holders" ]]; then
        if printf '%s\n' "$holders" | grep -Eq "users:\(\(\"(sing-box|${UNIT_NAME})\""; then
          log "port $spec is already held by sing-box; treat this as an upgrade"
        elif printf '%s\n' "$holders" | grep -q 'users:(("sing-box"'; then
          log "port $spec is already held by sing-box; treat this as an upgrade"
        else
          # If only our unit should own 443, anything else is a conflict.
          if printf '%s\n' "$holders" | grep -Eq 'users:\(\("?(nginx|caddy|apache2|httpd|haproxy|traefik|envoy)'; then
            err "port $spec is already in use by an unrelated process:"
            printf '%s\n' "$holders" | sed 's/^/  /' >&2
            die "refusing to overwrite an unrelated service's port"
          fi
          # Unknown listener: still refuse on apply so we do not steal the port.
          err "port $spec appears to be in use:"
          printf '%s\n' "$holders" | sed 's/^/  /' >&2
          if [[ "$APPLY" -eq 1 ]]; then
            die "refusing to bind a port already in use; pass --skip-port-check only if this is our service"
          else
            warn "dry-run: port conflict would block --apply"
          fi
        fi
      else
        log "port $spec is free on this host"
      fi
    done <<< "$listen_ports"
  else
    warn "ss not found; skipping live port checks"
  fi
else
  planned "skip live host port checks (dest-root is not / and --force-port-check was not set, or --skip-port-check)"
fi

# Do not touch a different unit that happens to also be named sing-box.
if [[ -e "$DEST_ROOT/etc/systemd/system/sing-box.service" || -e "$DEST_ROOT/lib/systemd/system/sing-box.service" || -e /lib/systemd/system/sing-box.service ]]; then
  if [[ "$UNIT_NAME" != "sing-box" ]]; then
    log "note: a different sing-box.service exists; this script will not modify it"
  fi
fi

if [[ -e "$UNIT_DEST" ]]; then
  if grep -Eq "ExecStart=.*/sing-box[[:space:]]+run[[:space:]]+-c[[:space:]].*sing-box-${INSTANCE}/config\.json" "$UNIT_DEST" \
     || grep -Fq "ExecStart=${RUNTIME_BIN_PATH} run -c ${RUNTIME_CONFIG_PATH}" "$UNIT_DEST" \
     || grep -Eq "ExecStart=.*/sing-box[[:space:]]+run[[:space:]]+-c[[:space:]].*${UNIT_NAME#sing-box-}/config\.json" "$UNIT_DEST"; then
    log "existing unit $UNIT_DEST looks like this kit; it will be backed up and replaced"
  else
    err "existing unit $UNIT_DEST does not look like this kit's ExecStart"
    die "refusing to overwrite an unrelated systemd unit"
  fi
fi

planned "backup existing same-name files under $BACKUP_DIR, if any"
planned "run sing-box check on the supplied config (without printing it)"
planned "atomically install config $CONFIG_DEST (0600) and unit $UNIT_DEST"
planned "directory $CONFIG_DIR mode 0700"
if [[ "$USE_SYSTEMD" -eq 1 ]]; then
  planned "systemctl daemon-reload && enable --now ${UNIT_NAME}.service"
fi
if [[ "$HARDEN" -eq 1 ]]; then
  if [[ "$DEST_ROOT" != "/" ]]; then
    die "refusing --harden when --dest-root is not / (that would change the host firewall)"
  fi
  planned "optional harden-ubuntu.sh (detect SSH port, UFW 22/443, BBR, chmod 600)"
fi

if [[ "$APPLY" -eq 0 ]]; then
  log "[deploy] dry-run only; no files, packages, firewall rules, or services were changed"
  log "re-run with --apply to perform the install"
  exit 0
fi

# ---------- apply ----------
WORK_DIR="$(mktemp -d -t proxy-deploy.XXXXXX)"
chmod 700 "$WORK_DIR"
BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_PATH="$BACKUP_DIR/${UNIT_NAME}-${BACKUP_STAMP}"
mkdir -p "$BACKUP_PATH" "$CONFIG_DIR" "$BIN_DIR" "$(dirname "$UNIT_DEST")" "$BACKUP_DIR"
chmod 700 "$CONFIG_DIR" "$BACKUP_PATH"

if [[ -e "$CONFIG_DEST" ]]; then
  HAD_CONFIG=1
  cp -a -- "$CONFIG_DEST" "$BACKUP_PATH/config.json"
  chmod 600 "$BACKUP_PATH/config.json"
  log "backed up existing config to $BACKUP_PATH/config.json"
fi
if [[ -e "$UNIT_DEST" ]]; then
  HAD_UNIT=1
  cp -a -- "$UNIT_DEST" "$BACKUP_PATH/${UNIT_NAME}.service"
  log "backed up existing unit to $BACKUP_PATH/${UNIT_NAME}.service"
fi
if [[ -e "$BIN_DEST" ]]; then
  HAD_BINARY=1
  cp -a -- "$BIN_DEST" "$BACKUP_PATH/sing-box"
  log "backed up existing binary to $BACKUP_PATH/sing-box"
fi

if [[ "$USE_SYSTEMD" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
  if systemctl cat "${UNIT_NAME}.service" >/dev/null 2>&1; then
    ORIG_ACTIVE="$(systemctl is-active "${UNIT_NAME}.service" 2>/dev/null || true)"
    ORIG_ENABLED="$(systemctl is-enabled "${UNIT_NAME}.service" 2>/dev/null || true)"
  else
    ORIG_ACTIVE="missing"
    ORIG_ENABLED="missing"
  fi
  log "original service state: active=$ORIG_ACTIVE enabled=$ORIG_ENABLED"
  printf 'active=%s\nenabled=%s\n' "$ORIG_ACTIVE" "$ORIG_ENABLED" > "$BACKUP_PATH/service-state.txt"
fi

NEED_ROLLBACK=1

STAGED_BIN=""
if [[ "$SKIP_DOWNLOAD" -eq 0 ]]; then
  archive="$WORK_DIR/$ASSET"
  log "downloading official release (this may take a while)"
  curl -fL --retry 3 --retry-delay 2 --user-agent "proxy-deploy-kit" \
    --output "$archive" "$RESOLVED_URL"
  got="$(sha256sum "$archive" | awk '{print $1}')"
  want="${RESOLVED_DIGEST#sha256:}"
  if [[ "$got" != "$want" ]]; then
    die "sha256 mismatch for $ASSET (got $got, expected $want); leaving the host unchanged"
  fi
  log "sha256 verified"
  mkdir -p "$WORK_DIR/extract"
  tar -xzf "$archive" -C "$WORK_DIR/extract"
  STAGED_BIN="$(find "$WORK_DIR/extract" -type f -name sing-box -perm /111 | head -n 1)"
  [[ -n "$STAGED_BIN" && -x "$STAGED_BIN" ]] || die "archive did not contain an executable sing-box binary"
else
  STAGED_BIN="$SING_BOX_BIN"
fi

# Validate with the binary we are about to install, before replacing anything live.
if ! "$STAGED_BIN" check -c "$CONFIG_SRC"; then
  die "sing-box check failed; the JSON may parse but it is not a usable sing-box config. Nothing was replaced."
fi
log "sing-box check passed"

# Stage files, then replace atomically (same filesystem mv).
stage_cfg="$WORK_DIR/config.json"
umask 077
# install(1) copies bytes; we do not echo or cat the file.
install -m 0600 "$CONFIG_SRC" "$stage_cfg"
stage_unit="$WORK_DIR/${UNIT_NAME}.service"
sed \
  -e "s|__UNIT_NAME__|${UNIT_NAME}|g" \
  -e "s|__BIN_DEST__|${RUNTIME_BIN_PATH}|g" \
  -e "s|__CONFIG_DEST__|${RUNTIME_CONFIG_PATH}|g" \
  "$UNIT_SRC" > "$stage_unit"
chmod 0644 "$stage_unit"

install -m 0600 "$stage_cfg" "$CONFIG_DEST.tmp.$$"
mv -f -- "$CONFIG_DEST.tmp.$$" "$CONFIG_DEST"
chmod 600 "$CONFIG_DEST"
WROTE_CONFIG=1
log "installed config $CONFIG_DEST (0600)"

# Copy sibling TLS files from the rendered server dir (hy2.crt / hy2.key, etc.).
SRC_CFG_DIR="$(dirname "$CONFIG_SRC")"
mkdir -p "$BACKUP_PATH/certs"
: > "$BACKUP_PATH/certs-created.txt"
for ext_f in "$SRC_CFG_DIR"/*.crt "$SRC_CFG_DIR"/*.key "$SRC_CFG_DIR"/*.pem; do
  [[ -f "$ext_f" ]] || continue
  dest_cert="$CONFIG_DIR/$(basename "$ext_f")"
  if [[ "$(realpath -m "$ext_f")" == "$(realpath -m "$dest_cert")" ]]; then
    continue
  fi
  if [[ -f "$dest_cert" ]]; then
    cp -a -- "$dest_cert" "$BACKUP_PATH/certs/$(basename "$ext_f")"
    HAD_CERTS=1
  else
    printf '%s\n' "$dest_cert" >> "$BACKUP_PATH/certs-created.txt"
  fi
  install -m 0600 "$ext_f" "$dest_cert"
  WROTE_CERTS=1
  log "installed $(basename "$ext_f") next to the config (0600)"
done

install -m 0644 "$stage_unit" "$UNIT_DEST.tmp.$$"
mv -f -- "$UNIT_DEST.tmp.$$" "$UNIT_DEST"
WROTE_UNIT=1
log "installed unit $UNIT_DEST"

if [[ "$STAGED_BIN" != "$BIN_DEST" ]]; then
  install -m 0755 "$STAGED_BIN" "$BIN_DEST.tmp.$$"
  mv -f -- "$BIN_DEST.tmp.$$" "$BIN_DEST"
  chmod 0755 "$BIN_DEST"
  WROTE_BINARY=1
  log "installed binary $BIN_DEST"
else
  log "binary already at $BIN_DEST; not replaced"
fi

if [[ "$USE_SYSTEMD" -eq 1 ]]; then
  DID_DAEMON_RELOAD=1
  systemctl daemon-reload
  systemctl enable "${UNIT_NAME}.service"
  DID_START=1
  if [[ "$ORIG_ACTIVE" == "active" ]]; then
    systemctl restart "${UNIT_NAME}.service"
  else
    systemctl start "${UNIT_NAME}.service"
  fi
  if ! systemctl is-active --quiet "${UNIT_NAME}.service"; then
    die "${UNIT_NAME}.service failed to become active"
  fi
  log "service ${UNIT_NAME}.service is active"
fi

NEED_ROLLBACK=0

if [[ "$HARDEN" -eq 1 ]]; then
  harden_args=()
  [[ "$APPLY" -eq 1 ]] && harden_args+=(--apply)
  harden_args+=(--instance "$INSTANCE" --config "$CONFIG_DEST")
  [[ -e "${CONFIG_DIR}/tls-key.pem" ]] && harden_args+=(--config "${CONFIG_DIR}/tls-key.pem")
  [[ -e "${CONFIG_DIR}/tls-cert.pem" ]] && harden_args+=(--config "${CONFIG_DIR}/tls-cert.pem")
  harden_args+=(--backup-dir "$BACKUP_DIR")
  [[ -n "$SSH_PORT" ]] && harden_args+=(--ssh-port "$SSH_PORT")
  log "running optional harden-ubuntu.sh ${harden_args[*]}"
  if ! "$SCRIPT_DIR/harden-ubuntu.sh" "${harden_args[@]}"; then
    err "harden-ubuntu.sh failed. The proxy files and service were already installed and were NOT rolled back. Fix UFW/SSH access before retrying harden."
    exit 1
  fi
fi

log "[deploy] done"
log "backups: $BACKUP_PATH"
log "A later failed run of this script rolls back that run only. It does not undo a successful --harden."
