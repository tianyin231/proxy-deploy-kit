#!/usr/bin/env bash
# Post-deploy verification for the sing-box transit host (and optional exit checks).
# Exit code 0 = all selected checks passed; 1 = at least one failed; 2 = usage error.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: verify-proxy.sh [options]

  --config PATH          sing-box config (default: /etc/sing-box-jp/config.json)
  --service NAME         systemd unit (default: sing-box-jp)
  --sing-box PATH        sing-box binary (default: sing-box or /usr/local/bin/sing-box)
  --proxy URL            Optional HTTP/SOCKS proxy used for exit/DNS/IPv6/Gemini tests
                         e.g. http://127.0.0.1:7890  or  socks5://127.0.0.1:7890
  --expect-exit-ip IP    Fail if the IPv4 exit IP is not exactly this value
  --expect-no-ipv6       Fail unless https://ipv6.icanhazip.com times out / is empty
  --journal-since SPEC   journalctl --since (default: 20 min ago)
  --skip-network         Only run local checks (sing-box, UFW, BBR, journal, config audit)
  --gemini-url URL       Default: https://gemini.google.com/app
  -h, --help             Show this help

The six checks from the deploy README:
  1. sing-box check + static DNS/route audit
  2. Exit IPv4 (https://api.ipify.org)
  3. DNS leak hint (encrypted-DNS / detour audit plus optional resolver hints)
  4. IPv6 block (https://ipv6.icanhazip.com)
  5. Gemini first hop without cookies (200 vs 302 sorry/index)
  6. Recent journalctl errors (EOF / connection reset / timeout / flow mismatch)
USAGE
}

CONFIG=/etc/sing-box-jp/config.json
SERVICE=sing-box-jp
SING_BOX=""
PROXY=""
EXPECT_EXIT_IP=""
EXPECT_NO_IPV6=0
SKIP_NETWORK=0
JOURNAL_SINCE="20 min ago"
GEMINI_URL="https://gemini.google.com/app"
CURL_MAX=15

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "error: --config requires a path" >&2; exit 2; }
      CONFIG="$2"; shift 2 ;;
    --service)
      [[ $# -ge 2 ]] || { echo "error: --service requires a name" >&2; exit 2; }
      SERVICE="$2"; shift 2 ;;
    --sing-box)
      [[ $# -ge 2 ]] || { echo "error: --sing-box requires a path" >&2; exit 2; }
      SING_BOX="$2"; shift 2 ;;
    --proxy)
      [[ $# -ge 2 ]] || { echo "error: --proxy requires a URL" >&2; exit 2; }
      PROXY="$2"; shift 2 ;;
    --expect-exit-ip)
      [[ $# -ge 2 ]] || { echo "error: --expect-exit-ip requires an IP" >&2; exit 2; }
      EXPECT_EXIT_IP="$2"; shift 2 ;;
    --expect-no-ipv6) EXPECT_NO_IPV6=1; shift ;;
    --skip-network) SKIP_NETWORK=1; shift ;;
    --journal-since)
      [[ $# -ge 2 ]] || { echo "error: --journal-since requires a value" >&2; exit 2; }
      JOURNAL_SINCE="$2"; shift 2 ;;
    --gemini-url)
      [[ $# -ge 2 ]] || { echo "error: --gemini-url requires a URL" >&2; exit 2; }
      GEMINI_URL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
WARN=0

ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
head1(){ echo; echo "==> $*"; }

find_singbox() {
  if [[ -n "$SING_BOX" && -x "$SING_BOX" ]]; then
    echo "$SING_BOX"; return
  fi
  if command -v sing-box >/dev/null 2>&1; then
    command -v sing-box; return
  fi
  if [[ -x /usr/local/bin/sing-box ]]; then
    echo /usr/local/bin/sing-box; return
  fi
  return 1
}

curl_base() {
  local args=(curl -fsS --max-time "$CURL_MAX" --retry 0)
  if [[ -n "$PROXY" ]]; then
    args+=(-x "$PROXY")
  fi
  "${args[@]}" "$@"
}

# ---------- 1. sing-box check + config audit ----------
head1 "1. sing-box check and static config audit"
if [[ ! -f "$CONFIG" ]]; then
  bad "config not found: $CONFIG"
else
  if find_singbox >/dev/null; then
    SB="$(find_singbox)"
    if "$SB" check -c "$CONFIG"; then
      ok "sing-box check -c $CONFIG"
    else
      bad "sing-box check failed for $CONFIG"
    fi
  else
    warn "sing-box binary not found; skipped 'sing-box check'"
  fi

  audit_out="$(python3 - "$CONFIG" <<'AUDITPY'
import json, sys, re
path = sys.argv[1]
try:
    cfg = json.load(open(path))
except Exception as e:
    print("FAIL:cannot parse config:", e)
    sys.exit(0)

problems, notes = [], []
for s in (cfg.get("dns") or {}).get("servers") or []:
    typ, tag = s.get("type"), s.get("tag", "?")
    if typ in ("udp", "tcp", "local") and ("starzone" in str(tag) or s.get("detour")):
        problems.append(
            f"DNS server {tag} uses plaintext type={typ}; use tls/https inside the landing tunnel"
        )
    if str(tag).startswith("starzone") or "wg-dns" in str(tag):
        if typ not in ("tls", "https", "quic", "h3"):
            problems.append(f"landing DNS {tag} should be encrypted (tls/https), got type={typ}")
        if not s.get("detour"):
            problems.append(f"landing DNS {tag} has no detour; queries may leak to the transit resolver")

rules = (cfg.get("route") or {}).get("rules") or []
if not rules:
    problems.append("route.rules is empty")
else:
    if not any(r.get("network") == "udp" and r.get("action") == "reject" for r in rules):
        problems.append("missing inbound app-layer UDP reject rule")
    if not any(r.get("ip_is_private") and r.get("action") == "reject" for r in rules):
        problems.append("missing ip_is_private reject rule")
    if rules[-1].get("action") != "reject":
        problems.append("last route rule is not a reject fallback; leaked traffic may go DIRECT")
    if not any(
        r.get("action") == "reject" and r.get("inbound")
        for r in rules
        if any("starzone" in str(x) or str(x).startswith("exit-") for x in (r.get("inbound") or []))
    ):
        notes.append("no explicit reject for the WireGuard endpoint inbound (confirm tunnel hairpin is denied)")

ph = sorted(set(re.findall(r"<[A-Z0-9_]+>", json.dumps(cfg))))
if ph:
    problems.append("unfilled placeholders still present: " + ", ".join(ph))

for item in problems:
    print("FAIL:" + item)
for item in notes:
    print("WARN:" + item)
if not problems:
    print("OK")
AUDITPY
  )" || true
  if [[ -z "$audit_out" ]]; then
    warn "config audit produced no output (python3 missing?)"
  else
    audit_failed=0
    while IFS= read -r line; do
      case "$line" in
        FAIL:*) bad "${line#FAIL:}"; audit_failed=1 ;;
        WARN:*) warn "${line#WARN:}" ;;
        OK) ;;
        *) echo "    $line" ;;
      esac
    done <<< "$audit_out"
    if [[ "$audit_failed" -eq 0 ]]; then
      ok "static DNS / route audit"
    fi
  fi
fi

# ---------- UFW + BBR (supporting local checks) ----------
head1 "UFW and BBR"
if command -v ufw >/dev/null 2>&1; then
  ufw_out="$(ufw status 2>/dev/null || true)"
  echo "$ufw_out" | sed 's/^/    /'
  if echo "$ufw_out" | grep -qi '^Status: inactive'; then
    bad "UFW is inactive"
  elif echo "$ufw_out" | grep -qi '^Status: active'; then
    missing=()
    echo "$ufw_out" | grep -qE '22/tcp' || missing+=("22/tcp")
    echo "$ufw_out" | grep -qE '443/tcp' || missing+=("443/tcp")
    echo "$ufw_out" | grep -qE '443/udp' || missing+=("443/udp")
    if [[ ${#missing[@]} -eq 0 ]]; then
      ok "UFW active and allows 22/tcp, 443/tcp, 443/udp"
    else
      bad "UFW active but missing allow rules: ${missing[*]}"
    fi
  else
    warn "could not parse UFW status (need root?)"
  fi
else
  warn "UFW not installed"
fi

if qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" && \
   cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"; then
  echo "    net.core.default_qdisc=$qdisc"
  echo "    net.ipv4.tcp_congestion_control=$cc"
  if [[ "$qdisc" == "fq" && "$cc" == "bbr" ]]; then
    ok "BBR + fq enabled"
  else
    bad "expected fq/bbr, got ${qdisc:-?}/${cc:-?}"
  fi
else
  warn "could not read sysctl (non-Linux or no permission)"
fi

# ---------- 2 / 3 / 4 / 5 network checks ----------
if [[ "$SKIP_NETWORK" -eq 1 ]]; then
  head1 "Network checks skipped (--skip-network)"
else
  curl_via="direct"
  [[ -n "$PROXY" ]] && curl_via="proxy $PROXY"

  head1 "2. Exit IPv4 ($curl_via)"
  if exit_ip="$(curl_base https://api.ipify.org 2>/tmp/verify-ipify.err || true)"; then
    :
  fi
  if [[ -z "${exit_ip:-}" ]]; then
    bad "could not fetch https://api.ipify.org  $(tr '\n' ' ' </tmp/verify-ipify.err 2>/dev/null)"
  else
    echo "    exit IPv4: $exit_ip"
    if [[ -n "$EXPECT_EXIT_IP" ]]; then
      if [[ "$exit_ip" == "$EXPECT_EXIT_IP" ]]; then
        ok "exit IP matches --expect-exit-ip"
      else
        bad "exit IP $exit_ip != expected $EXPECT_EXIT_IP"
      fi
    else
      ok "got exit IPv4 $exit_ip (pass --expect-exit-ip to pin it)"
    fi
  fi

  head1 "3. DNS leak hint ($curl_via)"
  # Two inexpensive signals:
  #   - Cloudflare trace shows the connecting IP (should equal the exit IP)
  #   - ip-api DNS endpoint reports the resolver seen by the probe, when reachable
  if trace="$(curl_base https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)"; then
    trace_ip="$(printf '%s\n' "$trace" | awk -F= '/^ip=/{print $2}')"
    trace_loc="$(printf '%s\n' "$trace" | awk -F= '/^loc=/{print $2}')"
    trace_colo="$(printf '%s\n' "$trace" | awk -F= '/^colo=/{print $2}')"
    echo "    cloudflare trace ip=${trace_ip:-?} loc=${trace_loc:-?} colo=${trace_colo:-?}"
    if [[ -n "${exit_ip:-}" && -n "$trace_ip" && "$trace_ip" != "$exit_ip" ]]; then
      bad "cloudflare trace IP $trace_ip differs from api.ipify.org $exit_ip"
    else
      ok "cloudflare trace reachable (loc=${trace_loc:-?} colo=${trace_colo:-?})"
    fi
  else
    warn "could not reach https://1.1.1.1/cdn-cgi/trace"
  fi
  if dns_json="$(curl_base https://edns.ip-api.com/json 2>/dev/null || true)"; then
    echo "    edns.ip-api.com: $dns_json"
    ok "fetched a resolver hint from edns.ip-api.com (anycast GeoIP is not proof of local DNS)"
  else
    warn "edns.ip-api.com not reachable; skip the optional resolver hint"
  fi

  head1 "4. IPv6 block ($curl_via)"
  set +e
  v6_out="$(curl -sS --max-time 8 ${PROXY:+-x "$PROXY"} -6 https://ipv6.icanhazip.com 2>/tmp/verify-v6.err)"
  v6_rc=$?
  set -e
  v6_out="$(printf '%s' "$v6_out" | tr -d '[:space:]')"
  if [[ -n "$v6_out" ]]; then
    echo "    ipv6.icanhazip.com -> $v6_out"
    if [[ "$EXPECT_NO_IPV6" -eq 1 ]]; then
      bad "IPv6 is reachable on this probe ($v6_out). That fails --expect-no-ipv6, but this single URL does not prove other apps cannot use IPv6."
    else
      warn "IPv6 is reachable on this probe ($v6_out). For an ipv4_only landing this request should be empty. That does not prove the OS or other apps cannot leak IPv6. Pass --expect-no-ipv6 to fail the script."
    fi
  else
    echo "    no IPv6 response on this probe (curl exit $v6_rc). That is expected for an ipv4_only landing, but it does not prove end-to-end IPv6 cannot leak."
    ok "ipv6.icanhazip.com empty or timed out on this probe"
  fi

  head1 "5. Gemini first hop, no cookies ($curl_via)"
  # --max-redirs 0 so we inspect the first response only (clients/unlock testers do this)
  gemini_headers="$(
    curl -sS --max-time "$CURL_MAX" -D - -o /dev/null --max-redirs 0 \
      ${PROXY:+-x "$PROXY"} -A 'Mozilla/5.0' "$GEMINI_URL" 2>/tmp/verify-gemini.err || true
  )"
  if [[ -z "$gemini_headers" ]]; then
    bad "no response from $GEMINI_URL  $(tr '\n' ' ' </tmp/verify-gemini.err 2>/dev/null)"
  else
    status="$(printf '%s\n' "$gemini_headers" | awk 'BEGIN{IGNORECASE=1} /^HTTP\//{print $2; exit}')"
    location="$(printf '%s\n' "$gemini_headers" | awk 'BEGIN{IGNORECASE=1} /^Location:/{sub("\r",""); print $0; exit}')"
    echo "    HTTP $status ${location}"
    loc_lc="$(printf '%s' "$location" | tr '[:upper:]' '[:lower:]')"
    if [[ "$status" == "200" ]]; then
      ok "Gemini first hop is 200 — this exit is not in a sorry/index loop"
    elif [[ "$status" == "302" || "$status" == "303" || "$status" == "307" || "$status" == "308" ]]; then
      if printf '%s' "$loc_lc" | grep -q 'sorry/index'; then
        warn "Gemini 302 to google.com/sorry/index. That is a temporary interstitial for this egress IP, not proof of an account ban or a permanent IP block, and not by itself a sing-box misconfig. Testers that do not store cookies will time out; a real browser often still works after 2-3 hops."
      else
        warn "Gemini redirected (HTTP $status) to ${location:-?} — not a sorry/index loop, inspect manually"
      fi
    else
      warn "Gemini unexpected HTTP $status"
    fi
  fi
fi

# ---------- 6. journalctl ----------
head1 "6. Recent journalctl errors (since: $JOURNAL_SINCE)"
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${SERVICE}.service" >/dev/null 2>&1; then
  if systemctl is-active --quiet "$SERVICE"; then
    ok "service $SERVICE is active"
  else
    bad "service $SERVICE is not active ($(systemctl is-active "$SERVICE" 2>/dev/null || true))"
  fi
  log="$(journalctl -u "$SERVICE" --since "$JOURNAL_SINCE" --no-pager -o cat 2>/tmp/verify-journal.err || true)"
  if [[ -z "$log" && -s /tmp/verify-journal.err ]]; then
    warn "journalctl failed: $(tr '\n' ' ' </tmp/verify-journal.err)"
  else
    hits="$(printf '%s\n' "$log" | grep -Ei 'flow mismatch|connection reset|i/o timeout|io timeout|\bEOF\b|context deadline exceeded' || true)"
    # Reality "processed invalid connection" from public scanners is expected and not counted as a failure
    if [[ -n "$hits" ]]; then
      echo "$hits" | sed 's/^/    /' | tail -n 40
      bad "found EOF / reset / timeout / flow mismatch in the last window (see lines above)"
    else
      ok "no EOF / connection reset / timeout / flow mismatch in the last window"
      if printf '%s\n' "$log" | grep -qi 'REALITY: processed invalid connection'; then
        warn "REALITY 'processed invalid connection' is present — usually public scanners hitting TCP 443, safe to ignore"
      fi
    fi
  fi
else
  warn "systemd unit ${SERVICE}.service not found on this host"
fi

echo
echo "---- summary: $PASS passed, $WARN warnings, $FAIL failed ----"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
