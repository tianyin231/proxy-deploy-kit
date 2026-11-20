#!/usr/bin/env bash
# Post-deploy verification suite for any sing-box relay instance.
# Supports --profile base (general relay) and --profile ai (adds Gemini first-hop check).
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: verify-proxy.sh [options]

  --instance NAME        Instance slug (default: relay -> sing-box-relay & /etc/sing-box-relay/config.json)
  --config PATH          Override sing-box config path
  --service NAME         Override systemd unit name
  --sing-box PATH        Override sing-box binary path
  --proxy URL            HTTP or SOCKS5 proxy URL for live network checks (e.g. http://127.0.0.1:7890)
  --profile MODE         Verification profile: base | ai (default: base; 'ai' enables Gemini check)
  --expect-exit-ip IP    Fail if egress IPv4 does not equal IP
  --expect-no-ipv6       Fail if ipv6.icanhazip.com succeeds over proxy
  --journal-since SPEC   journalctl --since window (default: "20 min ago")
  --skip-network         Run local static & host checks only
  --gemini-url URL       AI first-hop URL (default: https://gemini.google.com/app; implies --profile ai)
  -h, --help             Show this help
USAGE
}

INSTANCE="relay"
CONFIG=""
SERVICE=""
SING_BOX=""
PROXY=""
PROFILE="base"
EXPECT_EXIT_IP=""
EXPECT_NO_IPV6=0
SKIP_NETWORK=0
JOURNAL_SINCE="20 min ago"
GEMINI_URL="https://gemini.google.com/app"
CURL_MAX=15

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)
      [[ $# -ge 2 ]] || { echo "error: --instance requires a name" >&2; exit 2; }
      INSTANCE="$2"; shift 2 ;;
    --config)
      [[ $# -ge 2 ]] || { echo "error: --config requires a path" >&2; exit 2; }
      CONFIG="$2"; shift 2 ;;
    --service)
      [[ $# -ge 2 ]] || { echo "error: --service requires a name" >&2; exit 2; }
      SERVICE="${2%.service}"; shift 2 ;;
    --sing-box)
      [[ $# -ge 2 ]] || { echo "error: --sing-box requires a path" >&2; exit 2; }
      SING_BOX="$2"; shift 2 ;;
    --proxy)
      [[ $# -ge 2 ]] || { echo "error: --proxy requires a URL" >&2; exit 2; }
      PROXY="$2"; shift 2 ;;
    --profile)
      [[ $# -ge 2 ]] || { echo "error: --profile requires base or ai" >&2; exit 2; }
      PROFILE="$2"; shift 2 ;;
    --expect-exit-ip)
      [[ $# -ge 2 ]] || { echo "error: --expect-exit-ip requires an IP" >&2; exit 2; }
      EXPECT_EXIT_IP="$2"; shift 2 ;;
    --expect-no-ipv6) EXPECT_NO_IPV6=1; shift ;;
    --skip-network) SKIP_NETWORK=1; shift ;;
    --journal-since)
      [[ $# -ge 2 ]] || { echo "error: --journal-since requires a time spec" >&2; exit 2; }
      JOURNAL_SINCE="$2"; shift 2 ;;
    --gemini-url)
      [[ $# -ge 2 ]] || { echo "error: --gemini-url requires a URL" >&2; exit 2; }
      GEMINI_URL="$2"; PROFILE="ai"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

CONFIG="${CONFIG:-/etc/sing-box-${INSTANCE}/config.json}"
SERVICE="${SERVICE:-sing-box-${INSTANCE}}"

PASS=0
FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $*" >&2; FAIL=$((FAIL + 1)); }
info() { echo "  [INFO] $*"; }

find_singbox() {
  if [[ -n "$SING_BOX" && -x "$SING_BOX" ]]; then echo "$SING_BOX"; return 0; fi
  if command -v sing-box >/dev/null 2>&1; then command -v sing-box; return 0; fi
  if [[ -x /usr/local/bin/sing-box ]]; then echo "/usr/local/bin/sing-box"; return 0; fi
  return 1
}

echo "==> 1) Config syntax & static route/DNS leak audit ($CONFIG)"
if [[ ! -f "$CONFIG" ]]; then
  bad "config not found: $CONFIG"
else
  if SB_BIN="$(find_singbox)"; then
    if "$SB_BIN" check -c "$CONFIG"; then
      ok "sing-box check passed"
    else
      bad "sing-box check failed"
    fi
  else
    info "sing-box binary not in PATH; running Python static audit only"
  fi

  if python3 - "$CONFIG" <<'PY'; then
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if re.search(r"<[A-Z0-9_]+>", raw):
    print("unfilled placeholders present", file=sys.stderr); sys.exit(1)
cfg = json.loads(raw)
rules = cfg.get("route", {}).get("rules", [])
if not any(r.get("ip_is_private") is True and r.get("action") == "reject" for r in rules):
    print("missing ip_is_private reject rule", file=sys.stderr); sys.exit(1)
PY
    ok "static JSON & private-IP SSRF guard verified"
  else
    bad "static JSON / SSRF guard check failed"
  fi
fi

echo "==> 2) Host BBR & service status ($SERVICE)"
if command -v sysctl >/dev/null 2>&1; then
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  info "tcp_congestion_control=$cc"
fi
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${SERVICE}.service" >/dev/null 2>&1; then
  if systemctl is-active --quiet "${SERVICE}.service"; then
    ok "${SERVICE}.service is active"
  else
    info "${SERVICE}.service not currently active on this host"
  fi
fi

echo "==> 3) Recent journalctl error scan ($SERVICE, since $JOURNAL_SINCE)"
if command -v journalctl >/dev/null 2>&1; then
  errs="$(journalctl -u "${SERVICE}.service" --since "$JOURNAL_SINCE" --no-pager 2>/dev/null | grep -Ei 'flow mismatch|fatal|panic' || true)"
  if [[ -n "$errs" ]]; then
    bad "critical log patterns found in ${SERVICE}.service"
  else
    ok "no fatal / flow-mismatch errors in recent logs"
  fi
fi

if [[ "$SKIP_NETWORK" -eq 0 ]]; then
  PROXY_ARGS=()
  if [[ -n "$PROXY" ]]; then PROXY_ARGS=(--proxy "$PROXY"); fi

  echo "==> 4) Egress IPv4 check"
  exit_ip="$(curl -fsSL --max-time "$CURL_MAX" "${PROXY_ARGS[@]}" https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$exit_ip" ]]; then
    bad "failed to fetch egress IPv4 from api.ipify.org"
  elif [[ -n "$EXPECT_EXIT_IP" && "$exit_ip" != "$EXPECT_EXIT_IP" ]]; then
    bad "egress IPv4 '$exit_ip' != expected '$EXPECT_EXIT_IP'"
  else
    ok "egress IPv4=$exit_ip"
  fi

  echo "==> 5) IPv6 leak check"
  v6_ip="$(curl -6 -fsSL --max-time 6 "${PROXY_ARGS[@]}" https://ipv6.icanhazip.com 2>/dev/null || true)"
  if [[ "$EXPECT_NO_IPV6" -eq 1 && -n "$v6_ip" ]]; then
    bad "unexpected IPv6 egress detected: $v6_ip"
  else
    ok "IPv6 check passed (response='${v6_ip:-blocked}')"
  fi

  if [[ "$PROFILE" == "ai" ]]; then
    echo "==> 6) AI / Gemini first-hop check ($GEMINI_URL)"
    code_loc="$(curl -sS -o /dev/null --max-time "$CURL_MAX" "${PROXY_ARGS[@]}" -w '%{http_code} %{redirect_url}' "$GEMINI_URL" || true)"
    http_code="${code_loc%% *}"
    redir="${code_loc#* }"
    if [[ "$redir" == *"sorry/index"* ]]; then
      bad "Gemini redirected to Google sorry/captcha ($redir)"
    elif [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
      ok "AI first-hop reachable (HTTP $http_code)"
    else
      bad "AI first-hop returned HTTP $http_code"
    fi
  else
    info "AI / Gemini check skipped (profile=$PROFILE; pass --profile ai to enable)"
  fi
else
  info "live network checks skipped (--skip-network)"
fi

echo
echo "Summary: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
