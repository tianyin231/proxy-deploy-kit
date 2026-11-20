#!/usr/bin/env bash
# Offline test suite. Never runs --apply against the real host root.
# Does not call real systemctl, ufw, or apt, and does not change the host root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY="$SCRIPT_DIR/deploy.sh"
INIT="$SCRIPT_DIR/init-config.sh"
HARDEN="$SCRIPT_DIR/harden-ubuntu.sh"
VERIFY="$SCRIPT_DIR/verify-proxy.sh"

PASS=0
FAIL=0
ok() { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

WORKDIR="$(mktemp -d -t proxy-deploy-test.XXXXXX)"
chmod 700 "$WORKDIR"
# Some hosts mount /tmp noexec; fall back to a repo-local temp dir.
probe="$WORKDIR/.exec-probe"
printf '#!/bin/sh\nexit 0\n' > "$probe" && chmod +x "$probe"
if ! "$probe" 2>/dev/null; then
  rm -rf "$WORKDIR"
  WORKDIR="$(mktemp -d "$REPO_ROOT/.tmp-test-XXXXXX")"
  chmod 700 "$WORKDIR"
fi
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

HOST_PATHS=(
  /etc/sing-box-jp
  /etc/sing-box-relay
  /etc/sing-box-sg-custom
  /etc/systemd/system/sing-box-jp.service
  /etc/systemd/system/sing-box-relay.service
  /usr/local/bin/sing-box
  /etc/sysctl.d/90-proxy-bbr.conf
)

snapshot_host() {
  python3 - "$WORKDIR/host-snap-paths" <<'PY'
import hashlib, json, os, sys
paths = [
    "/etc/sing-box-jp",
    "/etc/sing-box-relay",
    "/etc/sing-box-sg-custom",
    "/etc/systemd/system/sing-box-jp.service",
    "/etc/systemd/system/sing-box-relay.service",
    "/usr/local/bin/sing-box",
    "/etc/sysctl.d/90-proxy-bbr.conf",
]
out = {}
for path in paths:
    if os.path.islink(path) or os.path.isfile(path):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        st = os.lstat(path)
        out[path] = {"kind": "file", "sha256": h.hexdigest(), "mode": st.st_mode, "mtime": st.st_mtime_ns, "size": st.st_size}
    elif os.path.isdir(path):
        st = os.lstat(path)
        out[path] = {"kind": "dir", "mode": st.st_mode, "mtime": st.st_mtime_ns}
    else:
        out[path] = {"kind": "missing"}
print(json.dumps(out, sort_keys=True))
PY
}

echo "==> syntax"
syntax_ok=1
for f in deploy.sh init-config.sh harden-ubuntu.sh verify-proxy.sh test-deploy.sh; do
  if bash -n "$SCRIPT_DIR/$f"; then
    ok "bash -n scripts/$f"
  else
    bad "bash -n scripts/$f"
    syntax_ok=0
  fi
done
if python3 -m py_compile "$SCRIPT_DIR/render-topology.py" "$SCRIPT_DIR/test-render.py"; then
  ok "python3 -m py_compile render-topology.py test-render.py"
else
  bad "python3 -m py_compile failed"
fi

echo "==> renderer tests"
if python3 "$SCRIPT_DIR/render-topology.py" --selftest >/dev/null; then
  ok "render-topology.py --selftest"
else
  bad "render-topology.py --selftest"
fi
if python3 "$SCRIPT_DIR/test-render.py"; then
  ok "scripts/test-render.py suite"
else
  bad "scripts/test-render.py suite"
fi

echo "==> CLI guards"
set +e
out="$("$DEPLOY" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q -- '--config is required'; then
  ok "missing --config exits 2"
else
  bad "missing --config: rc=$rc"
fi

set +e
out="$("$DEPLOY" --config "$REPO_ROOT/server/config.template.json" --skip-os-check --skip-port-check --skip-download --sing-box-bin /bin/true 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'unfilled placeholders'; then
  ok "unfilled template rejected"
else
  bad "unfilled template was not rejected (rc=$rc)"
fi

echo "==> init-config"
init_out="$WORKDIR/from-init.json"
if "$INIT" --out "$init_out" >/dev/null && [[ "$(stat -c '%a' "$init_out")" == "600" ]]; then
  ok "init-config writes mode 600"
else
  bad "init-config did not write mode 600"
fi
set +e
out="$("$INIT" --out "$init_out" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qi 'refusing to overwrite'; then
  ok "init-config refuses overwrite"
else
  bad "init-config overwrite check failed (rc=$rc)"
fi

# Render a multi-exit topology with test credentials only.
TOPO="$WORKDIR/topo.yaml"
cat > "$TOPO" <<'EOF'
instance: sg-custom
relay:
  public_host: "203.0.113.55"
  listen_port: 8443
  ssh_port: 2222
  vless_reality:
    enabled: true
    server_name: www.cloudflare.com
  hysteria2:
    enabled: true
    up_mbps: 120
    down_mbps: 250
    cert_san: www.bing.com
    auto_self_signed: true
exits:
  - id: site-direct
    label: "本机直出"
    type: direct
    allow_udp: true
    groups: ["正常代理"]
  - id: line-http
    label: "专线 HTTP"
    type: http
    allow_udp: false
    groups: ["正常代理", "AI-Google"]
    upstream:
      host: "198.51.100.21"
      port: 3128
      username: "u-test"
      password: "p-test"
  - id: home-wg
    label: "家宽隧道"
    type: wireguard
    ip_strategy: ipv4_only
    dns_detour: true
    allow_udp: false
    groups: ["正常代理", "AI-Google"]
    upstream:
      local_ipv4: "10.77.0.2/32"
      private_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
      peer_host: "198.51.100.88"
      peer_port: 51820
      peer_public_key: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
clients:
  rule_profile: default
EOF

BUILD_OUT="$WORKDIR/build-sg"
if "$INIT" --topology "$TOPO" --out-dir "$BUILD_OUT" --generate-secrets >/dev/null \
  && [[ -f "$BUILD_OUT/server/config.json" && -f "$BUILD_OUT/server/hy2.key" && -f "$BUILD_OUT/clients/flclash.yaml" ]]; then
  ok "init-config --topology rendered server, certs and clients"
else
  bad "init-config --topology did not render expected artifacts"
fi
FILLED="$BUILD_OUT/server/config.json"
chmod 600 "$FILLED" "$BUILD_OUT/server/hy2.key" 2>/dev/null || true

# JSON/YAML sanity on generated artifacts
if python3 -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' "$FILLED"; then
  ok "generated server config is valid JSON"
else
  bad "generated server config is not valid JSON"
fi
if python3 -c 'import sys; from pathlib import Path; import importlib.util
spec=importlib.util.spec_from_file_location("rt", sys.argv[1])
' "$SCRIPT_DIR/render-topology.py" && python3 - "$BUILD_OUT/clients/flclash.yaml" <<'PY'
import sys
from pathlib import Path
# Minimal well-formedness: no tabs issues, has dns listen and rules
text = Path(sys.argv[1]).read_text(encoding="utf-8")
assert "listen: 127.0.0.1:1053" in text
assert "rules:" in text
print("YAML_OK")
PY
then
  ok "generated FlClash YAML has strict DNS listen and a rules section"
else
  bad "generated FlClash YAML failed basic checks"
fi

echo "==> dry-run writes nothing"
before="$(snapshot_host)"
set +e
out="$("$DEPLOY" --instance sg-custom --config "$FILLED" --skip-os-check --skip-port-check --dest-root "$WORKDIR/empty-root" 2>&1)"
rc=$?
set -e
after="$(snapshot_host)"
if [[ "$rc" -eq 0 && "$out" == *"dry-run only"* && "$before" == "$after" && ! -e "$WORKDIR/empty-root/etc/sing-box-sg-custom/config.json" ]]; then
  ok "dry-run changes neither the host nor dest-root"
else
  bad "dry-run wrote files or changed the host (rc=$rc)"
fi

# Mocks
MOCK="$WORKDIR/mock-bin"
STATE=""
mkdir -p "$MOCK"

cat > "$MOCK/sing-box" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "check" ]]; then
  if [[ "${SINGBOX_CHECK_FAIL:-0}" -eq 1 ]]; then
    echo "mock sing-box check failed (no config dumped)" >&2
    exit 1
  fi
  exit 0
fi
if [[ "${1:-}" == "version" ]]; then
  echo "sing-box version 1.14.4 (mock)"
  exit 0
fi
exit 0
EOF
chmod +x "$MOCK/sing-box"

cat > "$MOCK/systemctl" <<'EOF'
#!/usr/bin/env bash
STATE="${DEPLOY_TEST_SYSTEMD_STATE:?}"
cmd="${1:-}"
# Skip unit-name arguments after the verb.
shift || true
case "$cmd" in
  daemon-reload) exit 0 ;;
  enable)
    echo "enabled" > "$STATE/enabled"
    exit 0
    ;;
  disable)
    echo "disabled" > "$STATE/enabled"
    exit 0
    ;;
  restart|start)
    if [[ -f "$STATE/fail-start" ]]; then
      rm -f "$STATE/fail-start"
      echo "inactive" > "$STATE/active"
      exit 1
    fi
    echo "active" > "$STATE/active"
    exit 0
    ;;
  stop)
    echo "inactive" > "$STATE/active"
    exit 0
    ;;
  is-active)
    val="$(cat "$STATE/active" 2>/dev/null || echo missing)"
    printf '%s\n' "$val"
    [[ "$val" == "active" ]]
    ;;
  is-enabled)
    val="$(cat "$STATE/enabled" 2>/dev/null || echo missing)"
    printf '%s\n' "$val"
    [[ "$val" == "enabled" ]]
    ;;
  cat)
    # Presence check used when recording original state.
    if [[ -f "${STATE}/unit-missing" ]]; then
      exit 1
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MOCK/systemctl"

common_apply() {
  PATH="$MOCK:$PATH" \
    DEPLOY_TEST_SYSTEMD_STATE="$STATE" \
    SINGBOX_CHECK_FAIL="${SINGBOX_CHECK_FAIL:-0}" \
    "$DEPLOY" \
    --instance sg-custom \
    --config "$FILLED" \
    --apply \
    --allow-nonroot \
    --skip-os-check \
    --skip-port-check \
    --skip-download \
    --sing-box-bin "$MOCK/sing-box" \
    --force-systemd \
    "$@"
}

echo "==> sandboxed --apply"
STATE="$WORKDIR/state-ok"; mkdir -p "$STATE"
echo "missing" > "$STATE/active"
echo "missing" > "$STATE/enabled"
ROOT_OK="$WORKDIR/root-ok"
if common_apply --dest-root "$ROOT_OK" --backup-dir "$ROOT_OK/var/backups/proxy" >/dev/null \
  && [[ "$(stat -c '%a' "$ROOT_OK/etc/sing-box-sg-custom/config.json")" == "600" \
    && "$(stat -c '%a' "$ROOT_OK/etc/sing-box-sg-custom")" == "700" \
    && "$(stat -c '%a' "$ROOT_OK/etc/sing-box-sg-custom/hy2.key")" == "600" \
    && -x "$ROOT_OK/usr/local/bin/sing-box" \
    && -f "$ROOT_OK/etc/systemd/system/sing-box-sg-custom.service" \
    && "$(cat "$STATE/active")" == "active" ]]; then
  ok "apply installs 0600 config and cert, 0700 dir, unit, binary, and starts the service"
else
  bad "parameterized apply failed"
fi

if grep -q 'ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box-sg-custom/config.json' "$ROOT_OK/etc/systemd/system/sing-box-sg-custom.service"; then
  ok "rendered unit uses runtime paths for this instance"
else
  bad "rendered unit paths were wrong"
fi

echo "==> verify-proxy and harden (files only)"
if "$VERIFY" --instance sg-custom --config "$ROOT_OK/etc/sing-box-sg-custom/config.json" --sing-box "$MOCK/sing-box" --profile base --skip-network >/dev/null; then
  ok "verify-proxy.sh --profile base --skip-network"
else
  bad "verify-proxy.sh failed on the rendered config"
fi

chmod 644 "$ROOT_OK/etc/sing-box-sg-custom/hy2.key" "$ROOT_OK/etc/sing-box-sg-custom/hy2.crt"
python3 - "$ROOT_OK/etc/sing-box-sg-custom/config.json" "$ROOT_OK/etc/sing-box-sg-custom" <<'PY'
import json, sys
p, d = sys.argv[1], sys.argv[2]
c = json.load(open(p, encoding="utf-8"))
for ib in c.get("inbounds", []):
    tls = ib.get("tls") or {}
    if "certificate_path" in tls:
        tls["certificate_path"] = f"{d}/hy2.crt"
        tls["key_path"] = f"{d}/hy2.key"
json.dump(c, open(p, "w", encoding="utf-8"), indent=2)
PY
ALLOW_NONROOT_HARDEN=1 "$HARDEN" --apply --skip-ufw --skip-bbr --config "$ROOT_OK/etc/sing-box-sg-custom/config.json" --backup-dir "$ROOT_OK/var/backups/proxy" >/dev/null
if [[ "$(stat -c '%a' "$ROOT_OK/etc/sing-box-sg-custom/hy2.key")" == "600" && "$(stat -c '%a' "$ROOT_OK/etc/sing-box-sg-custom/hy2.crt")" == "600" ]]; then
  ok "harden-ubuntu.sh tightens discovered cert/key modes to 0600"
else
  bad "harden-ubuntu.sh did not tighten cert/key modes"
fi

echo "==> check failure leaves previous files"
STATE="$WORKDIR/state-chk"; mkdir -p "$STATE"
echo "active" > "$STATE/active"; echo "enabled" > "$STATE/enabled"
ROOT_CHK="$WORKDIR/root-chk"
mkdir -p "$ROOT_CHK/etc/sing-box-sg-custom" "$ROOT_CHK/usr/local/bin" "$ROOT_CHK/etc/systemd/system"
echo "OLD-CONFIG" > "$ROOT_CHK/etc/sing-box-sg-custom/config.json"
echo "OLD-BIN" > "$ROOT_CHK/usr/local/bin/sing-box"; chmod +x "$ROOT_CHK/usr/local/bin/sing-box"
echo "ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box-sg-custom/config.json" > "$ROOT_CHK/etc/systemd/system/sing-box-sg-custom.service"
set +e
out_chk="$(SINGBOX_CHECK_FAIL=1 common_apply --dest-root "$ROOT_CHK" --backup-dir "$ROOT_CHK/var/backups/proxy" 2>&1)"
rc_chk=$?
set -e
if [[ "$rc_chk" -ne 0 && "$out_chk" == *"Nothing was replaced"* && "$(cat "$ROOT_CHK/etc/sing-box-sg-custom/config.json")" == "OLD-CONFIG" && "$(cat "$ROOT_CHK/usr/local/bin/sing-box")" == "OLD-BIN" ]]; then
  ok "sing-box check failure leaves previous files untouched"
else
  bad "sing-box check failure test failed (rc=$rc_chk)"
fi

echo "==> start failure rolls back files and service state"
STATE="$WORKDIR/state-rb"; mkdir -p "$STATE"
echo "active" > "$STATE/active"; echo "enabled" > "$STATE/enabled"
touch "$STATE/fail-start"
ROOT_RB="$WORKDIR/root-rb"
mkdir -p "$ROOT_RB/etc/sing-box-sg-custom" "$ROOT_RB/usr/local/bin" "$ROOT_RB/etc/systemd/system"
echo "OLD-CONFIG" > "$ROOT_RB/etc/sing-box-sg-custom/config.json"
echo "OLD-BIN" > "$ROOT_RB/usr/local/bin/sing-box"; chmod +x "$ROOT_RB/usr/local/bin/sing-box"
printf '[Service]\nExecStart=/usr/local/bin/sing-box run -c /etc/sing-box-sg-custom/config.json\n' > "$ROOT_RB/etc/systemd/system/sing-box-sg-custom.service"
set +e
out_rb="$(common_apply --dest-root "$ROOT_RB" --backup-dir "$ROOT_RB/var/backups/proxy" 2>&1)"
rc_rb=$?
set -e
if [[ "$rc_rb" -ne 0 && "$out_rb" == *"rolling back"* \
  && "$(cat "$ROOT_RB/etc/sing-box-sg-custom/config.json")" == "OLD-CONFIG" \
  && "$(cat "$ROOT_RB/usr/local/bin/sing-box")" == "OLD-BIN" \
  && "$out_rb" == *"was active"* \
  && "$(cat "$STATE/active")" == "active" \
  && "$(cat "$STATE/enabled")" == "enabled" ]]; then
  ok "start failure rolls back config, binary, unit and restores active/enabled state"
else
  bad "start-failure rollback test failed (rc=$rc_rb)"
  printf '%s\n' "$out_rb" | tail -n 30 | sed 's/^/    /'
fi

echo "==> mid-write failure rolls back already-written files"
STATE="$WORKDIR/state-mw"; mkdir -p "$STATE"
echo "active" > "$STATE/active"; echo "enabled" > "$STATE/enabled"
ROOT_MW="$WORKDIR/root-mw"
mkdir -p "$ROOT_MW/etc/sing-box-sg-custom" "$ROOT_MW/usr/local/bin" "$ROOT_MW/etc/systemd/system"
echo "OLD-CONFIG" > "$ROOT_MW/etc/sing-box-sg-custom/config.json"
echo "OLD-BIN" > "$ROOT_MW/usr/local/bin/sing-box"; chmod +x "$ROOT_MW/usr/local/bin/sing-box"
printf '[Service]\nExecStart=/usr/local/bin/sing-box run -c /etc/sing-box-sg-custom/config.json\n' > "$ROOT_MW/etc/systemd/system/sing-box-sg-custom.service"
# Fail when install(1) writes the unit, after the config has already been replaced.
cat > "$MOCK/install" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == *.service.tmp.* || "$arg" == *.service ]]; then
    echo "simulated install failure while writing the unit" >&2
    exit 1
  fi
done
exec /usr/bin/install "$@"
EOF
chmod +x "$MOCK/install"
set +e
out_mw="$(common_apply --dest-root "$ROOT_MW" --backup-dir "$ROOT_MW/var/backups/proxy" 2>&1)"
rc_mw=$?
set -e
rm -f "$MOCK/install"
if [[ "$rc_mw" -ne 0 && "$out_mw" == *"rolling back"* && "$(cat "$ROOT_MW/etc/sing-box-sg-custom/config.json")" == "OLD-CONFIG" && "$(cat "$STATE/active")" == "active" ]]; then
  ok "failure after config write rolls back the config and service state"
else
  bad "mid-write rollback test failed (rc=$rc_mw)"
  printf '%s\n' "$out_mw" | tail -n 40 | sed 's/^/    /'
fi

echo "==> SHA-256 mismatch refuses to install"
STATE="$WORKDIR/state-hash"; mkdir -p "$STATE"
echo "missing" > "$STATE/active"; echo "missing" > "$STATE/enabled"
ROOT_HASH="$WORKDIR/root-hash"
mkdir -p "$ROOT_HASH"
cat > "$MOCK/curl" <<'EOF'
#!/usr/bin/env bash
# Write a dummy tarball to --output / -o, then exit 0. Never hits the network.
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -z "$out" ]]; then
  echo "mock curl: no output path" >&2
  exit 1
fi
# Not a real sing-box archive; verification must reject it.
printf 'not-an-official-tarball\n' > "$out"
exit 0
EOF
chmod +x "$MOCK/curl"
set +e
out_hash="$(PATH="$MOCK:$PATH" DEPLOY_TEST_SYSTEMD_STATE="$STATE" \
  "$DEPLOY" --instance sg-custom --config "$FILLED" --apply --allow-nonroot \
  --skip-os-check --skip-port-check --dest-root "$ROOT_HASH" \
  --expected-sha256 0000000000000000000000000000000000000000000000000000000000000000 \
  --backup-dir "$ROOT_HASH/var/backups/proxy" 2>&1)"
rc_hash=$?
set -e
rm -f "$MOCK/curl"
if [[ "$rc_hash" -ne 0 && "$out_hash" == *"sha256 mismatch"* && ! -e "$ROOT_HASH/etc/sing-box-sg-custom/config.json" && ! -e "$ROOT_HASH/usr/local/bin/sing-box" ]]; then
  ok "sha256 mismatch aborts before writing dest-root files"
else
  bad "sha256 mismatch test failed (rc=$rc_hash)"
  printf '%s\n' "$out_hash" | tail -n 30 | sed 's/^/    /'
fi

echo "==> unrelated port conflict fails"
STATE="$WORKDIR/state-port"; mkdir -p "$STATE"
echo "missing" > "$STATE/active"; echo "missing" > "$STATE/enabled"
ROOT_PORT="$WORKDIR/root-port"
# Config listens on 8443 (from the topology above).
cat > "$MOCK/ss" <<'EOF'
#!/usr/bin/env bash
# Pretend nginx is already bound to the inbound port.
# Real ss -ltnp uses: State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
echo "LISTEN 0 128 0.0.0.0:8443 0.0.0.0:* users:((\"nginx\",pid=99,fd=7))"
exit 0
EOF
chmod +x "$MOCK/ss"
set +e
out_port="$(PATH="$MOCK:$PATH" DEPLOY_TEST_SYSTEMD_STATE="$STATE" \
  "$DEPLOY" --instance sg-custom --config "$FILLED" --apply --allow-nonroot \
  --skip-os-check --force-port-check --skip-download --sing-box-bin "$MOCK/sing-box" \
  --force-systemd --dest-root "$ROOT_PORT" --backup-dir "$ROOT_PORT/var/backups/proxy" 2>&1)"
rc_port=$?
set -e
rm -f "$MOCK/ss"
if [[ "$rc_port" -ne 0 && ( "$out_port" == *"already in use"* || "$out_port" == *"refusing to bind"* || "$out_port" == *"unrelated"* ) && ! -e "$ROOT_PORT/etc/sing-box-sg-custom/config.json" ]]; then
  ok "unrelated port listener causes a hard failure before install"
else
  bad "port conflict test failed (rc=$rc_port)"
  printf '%s\n' "$out_port" | tail -n 30 | sed 's/^/    /'
fi

echo "==> official sing-box check (optional, isolated, non-root)"
# Download only to a temp dir, verify the GitHub release digest, then run `sing-box check`.
# Skip (do not fail the suite) if the network or digest lookup is unavailable.
SB_DIR="$WORKDIR/official-sing-box"
official_checked=0
official_skipped=0
if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  mkdir -p "$SB_DIR"
  set +e
  meta="$(python3 - <<'PY'
import json, sys, urllib.request
url = "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v1.14.4"
req = urllib.request.Request(url, headers={"User-Agent": "proxy-deploy-kit-test", "Accept": "application/vnd.github+json"})
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
except Exception as exc:
    print("ERROR")
    sys.exit(0)
for item in data.get("assets") or []:
    if item.get("name") == "sing-box-1.14.4-linux-amd64.tar.gz":
        print(item.get("digest") or "")
        print(item.get("browser_download_url") or "")
        break
PY
)"
  set -e
  digest="$(printf '%s\n' "$meta" | sed -n '1p')"
  url="$(printf '%s\n' "$meta" | sed -n '2p')"
  if [[ "$digest" == sha256:* && -n "$url" ]]; then
    if curl -fsSL --retry 2 --max-time 60 -o "$SB_DIR/sb.tgz" "$url"; then
      got="$(sha256sum "$SB_DIR/sb.tgz" | awk '{print $1}')"
      want="${digest#sha256:}"
      if [[ "$got" == "$want" ]]; then
        tar -xzf "$SB_DIR/sb.tgz" -C "$SB_DIR"
        SB_BIN="$(find "$SB_DIR" -type f -name sing-box -perm /111 | head -n 1)"
        CHECK_CFG="$SB_DIR/check-config.json"
        python3 - "$FILLED" "$CHECK_CFG" "$BUILD_OUT/server" <<'PY'
import json, sys
src, dest, certdir = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(src, encoding="utf-8"))
for ib in cfg.get("inbounds", []):
    tls = ib.get("tls") or {}
    for key in ("certificate_path", "key_path"):
        if key in tls:
            name = tls[key].rsplit("/", 1)[-1]
            tls[key] = certdir.rstrip("/") + "/" + name
json.dump(cfg, open(dest, "w", encoding="utf-8"), indent=2)
PY
        chmod 600 "$CHECK_CFG"
        if [[ -n "$SB_BIN" ]] && "$SB_BIN" check -c "$CHECK_CFG"; then
          ok "official sing-box v1.14.4 check accepted the generated config"
          official_checked=1
        else
          bad "official sing-box check rejected the generated config"
        fi
      else
        official_skipped=1
        echo "  [SKIP] official tarball sha256 did not match the GitHub digest; not running check"
      fi
    else
      official_skipped=1
      echo "  [SKIP] could not download the official sing-box release for check"
    fi
  else
    official_skipped=1
    echo "  [SKIP] could not read the official v1.14.4 digest from GitHub"
  fi
else
  official_skipped=1
  echo "  [SKIP] curl or python3 missing; official sing-box check not run"
fi

echo "==> host unchanged"
after_all="$(snapshot_host)"
if [[ "$before" == "$after_all" ]]; then
  ok "no host proxy paths were modified"
else
  bad "a host path changed during the isolated suite"
fi

echo
echo "=== Test Summary: PASS=$PASS FAIL=$FAIL official_check=$official_checked skipped_official=$official_skipped ==="
[[ "$FAIL" -eq 0 ]]
