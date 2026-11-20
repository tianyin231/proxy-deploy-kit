#!/usr/bin/env bash
# Smoke tests for deploy.sh. Never runs --apply against the real host root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY="$SCRIPT_DIR/deploy.sh"
INIT="$SCRIPT_DIR/init-config.sh"
PASS=0
FAIL=0

ok() { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
section() { printf '\n==> %s\n' "$*"; }

WORKDIR="$(mktemp -d -t proxy-deploy-test.XXXXXX)"
chmod 700 "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

section "bash -n"
for f in deploy.sh init-config.sh harden-ubuntu.sh verify-proxy.sh test-deploy.sh; do
  if bash -n "$SCRIPT_DIR/$f"; then
    ok "bash -n scripts/$f"
  else
    bad "bash -n scripts/$f"
  fi
done

section "missing --config is rejected"
set +e
out="$("$DEPLOY" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q -- '--config is required'; then
  ok "missing --config exits 2"
else
  bad "missing --config: rc=$rc"
fi

section "unfilled template is rejected"
set +e
out="$("$DEPLOY" --config "$REPO_ROOT/server/config.template.json" --skip-os-check --skip-port-check --skip-download --sing-box-bin /bin/true 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'unfilled placeholders'; then
  ok "unfilled template rejected"
else
  bad "unfilled template was not rejected (rc=$rc)"
fi

section "init-config refuses overwrite and writes 0600"
init_out="$WORKDIR/from-init.json"
if "$INIT" --out "$init_out" >/dev/null && [[ -f "$init_out" ]]; then
  mode="$(stat -c '%a' "$init_out")"
  if [[ "$mode" == "600" ]]; then
    ok "init-config created file mode 600"
  else
    bad "init-config mode was $mode, expected 600"
  fi
else
  bad "init-config failed to write"
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

# Fabricated values only, never production secrets.
FILLED="$WORKDIR/filled.json"
python3 - "$REPO_ROOT/server/config.template.json" "$FILLED" <<'PY'
import json, re, sys
src, dest = sys.argv[1], sys.argv[2]
raw = open(src, encoding="utf-8").read()
raw = re.sub(r'"<(?:HK|US|WG)_[A-Z0-9_]*PORT>"', "12345", raw)

def sub(match):
    name = match.group(0)
    if "UUID" in name:
        return "00000000-0000-4000-8000-000000000001"
    if name == "<WG_IPV4>":
        return "10.255.0.2"
    if "HOST" in name or "IPV4" in name:
        return "203.0.113.10"
    return "TESTPLACEHOLDERVALUE"

raw = re.sub(r"<[A-Z][A-Z0-9_]*>", sub, raw)
json.loads(raw)
open(dest, "w", encoding="utf-8").write(raw)
PY
chmod 600 "$FILLED"

section "dry-run makes zero changes on the real host"
snapshot() {
  python3 - <<'PY'
import os, hashlib, json
paths = [
    "/etc/sing-box-jp",
    "/etc/sing-box-jp/config.json",
    "/etc/systemd/system/sing-box-jp.service",
    "/usr/local/bin/sing-box",
    "/etc/sysctl.d/90-proxy-bbr.conf",
    "/etc/sysctl.d/90-ty2-proxy.conf",
]
out = {}
for path in paths:
    if os.path.islink(path) or os.path.isfile(path):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        st = os.lstat(path)
        out[path] = {
            "kind": "file",
            "sha256": h.hexdigest(),
            "mode": st.st_mode,
            "mtime": st.st_mtime_ns,
            "size": st.st_size,
        }
    elif os.path.isdir(path):
        st = os.lstat(path)
        out[path] = {"kind": "dir", "mode": st.st_mode, "mtime": st.st_mtime_ns}
    else:
        out[path] = {"kind": "missing"}
print(json.dumps(out, sort_keys=True))
PY
}
before="$(snapshot)"
set +e
out="$("$DEPLOY" --config "$FILLED" --skip-os-check --skip-port-check --dest-root "$WORKDIR/empty-root" 2>&1)"
rc=$?
set -e
after="$(snapshot)"
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'dry-run only'; then
  ok "dry-run exits 0 and reports no system changes"
else
  bad "dry-run unexpected rc=$rc"
  printf '%s\n' "$out" | sed 's/^/    /' | tail -n 20
fi
if [[ "$before" == "$after" ]]; then
  ok "dry-run left host proxy paths unchanged"
else
  bad "dry-run changed a host path"
fi
if [[ -e "$WORKDIR/empty-root/etc/sing-box-jp/config.json" || -e "$WORKDIR/empty-root/usr/local/bin/sing-box" ]]; then
  bad "dry-run wrote files under dest-root"
else
  ok "dry-run did not write dest-root files"
fi

MOCK="$WORKDIR/mockbin"
STATE="$WORKDIR/systemd-state"
mkdir -p "$MOCK" "$STATE"
cat > "$MOCK/sing-box" <<'MOCKSB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "check" ]]; then
  if [[ "${SINGBOX_CHECK_FAIL:-0}" == "1" ]]; then
    echo "mock sing-box check failed (no config dumped)" >&2
    exit 1
  fi
  exit 0
fi
if [[ "${1:-}" == "version" ]]; then
  echo "sing-box version 1.14.4 (mock)"
  exit 0
fi
echo "mock sing-box: unexpected args $*" >&2
exit 1
MOCKSB
chmod 755 "$MOCK/sing-box"

write_systemctl_mock() {
  cat > "$MOCK/systemctl" <<'MOCKCTL'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${DEPLOY_TEST_SYSTEMD_STATE:?}"
log="$STATE_DIR/log"
activef="$STATE_DIR/active"
enabledf="$STATE_DIR/enabled"
printf '%s\n' "$*" >> "$log"
cmd="${1:-}"
case "$cmd" in
  cat)
    if [[ "$(cat "$activef")" == "missing" ]]; then
      exit 1
    fi
    exit 0
    ;;
  is-active)
    quiet=0
    if [[ "${2:-}" == "--quiet" ]]; then
      quiet=1
      shift
    fi
    st="$(cat "$activef")"
    if [[ "$quiet" -eq 0 ]]; then
      printf '%s\n' "$st"
    fi
    if [[ "$st" == "active" ]]; then
      exit 0
    fi
    exit 1
    ;;
  is-enabled)
    st="$(cat "$enabledf")"
    printf '%s\n' "$st"
    if [[ "$st" == "enabled" ]]; then
      exit 0
    fi
    exit 1
    ;;
  daemon-reload)
    exit 0
    ;;
  enable)
    printf 'enabled\n' > "$enabledf"
    exit 0
    ;;
  disable)
    printf 'disabled\n' > "$enabledf"
    exit 0
    ;;
  start|restart)
    if [[ -f "$STATE_DIR/fail-start" ]]; then
      rm -f "$STATE_DIR/fail-start"
      printf 'failed\n' > "$activef"
      exit 1
    fi
    printf 'active\n' > "$activef"
    exit 0
    ;;
  stop)
    printf 'inactive\n' > "$activef"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCKCTL
  chmod 755 "$MOCK/systemctl"
}
write_systemctl_mock

common_apply() {
  # "$@" are extra deploy args
  env PATH="$MOCK:$PATH" \
    DEPLOY_TEST_SYSTEMD_STATE="$STATE" \
    SINGBOX_CHECK_FAIL="${SINGBOX_CHECK_FAIL:-0}" \
    "$DEPLOY" --config "$FILLED" \
      --apply --allow-nonroot --skip-os-check --skip-port-check \
      --skip-download --sing-box-bin "$MOCK/sing-box" \
      --force-systemd \
      "$@"
}

section "mock apply success under dest-root"
ROOT_OK="$WORKDIR/root-ok"
printf 'missing\n' > "$STATE/active"
printf 'missing\n' > "$STATE/enabled"
: > "$STATE/log"
rm -f "$STATE/fail-start"
set +e
out="$(common_apply --dest-root "$ROOT_OK" --backup-dir "$ROOT_OK/var/backups/proxy" 2>&1)"
rc=$?
set -e
cfg="$ROOT_OK/etc/sing-box-jp/config.json"
bin="$ROOT_OK/usr/local/bin/sing-box"
unit="$ROOT_OK/etc/systemd/system/sing-box-jp.service"
if [[ "$rc" -eq 0 && -f "$cfg" && -x "$bin" && -f "$unit" ]]; then
  ok "mock apply installed config, binary, and unit"
else
  bad "mock apply success path failed (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /' | tail -n 30
fi
if [[ -f "$cfg" && "$(stat -c '%a' "$cfg")" == "600" && "$(stat -c '%a' "$(dirname "$cfg")")" == "700" ]]; then
  ok "installed config is 0600 and directory is 0700"
else
  bad "unexpected config permissions"
fi
if [[ "$(cat "$STATE/active")" == "active" && "$(cat "$STATE/enabled")" == "enabled" ]]; then
  ok "mock systemd enabled and started the unit"
else
  bad "mock systemd state was $(cat "$STATE/active")/$(cat "$STATE/enabled")"
fi
# Host still untouched
after_apply="$(snapshot)"
if [[ "$before" == "$after_apply" ]]; then
  ok "successful dest-root apply did not change host proxy paths"
else
  bad "dest-root apply leaked writes onto the host"
fi

section "sing-box check failure leaves previous files in place"
ROOT_CHK="$WORKDIR/root-checkfail"
mkdir -p "$ROOT_CHK/etc/sing-box-jp" "$ROOT_CHK/usr/local/bin" "$ROOT_CHK/etc/systemd/system" "$ROOT_CHK/var/backups/proxy"
printf 'OLD-CONFIG\n' > "$ROOT_CHK/etc/sing-box-jp/config.json"
chmod 600 "$ROOT_CHK/etc/sing-box-jp/config.json"
printf 'OLD-UNIT\n' > "$ROOT_CHK/etc/systemd/system/sing-box-jp.service"
printf 'OLD-BIN\n' > "$ROOT_CHK/usr/local/bin/sing-box"
chmod 755 "$ROOT_CHK/usr/local/bin/sing-box"
# Existing unit must look like this kit, or deploy refuses to touch it.
cat > "$ROOT_CHK/etc/systemd/system/sing-box-jp.service" <<'UNIT'
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box-jp/config.json
UNIT
printf 'active\n' > "$STATE/active"
printf 'enabled\n' > "$STATE/enabled"
: > "$STATE/log"
rm -f "$STATE/fail-start"
set +e
out="$(SINGBOX_CHECK_FAIL=1 common_apply --dest-root "$ROOT_CHK" --backup-dir "$ROOT_CHK/var/backups/proxy" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'sing-box check failed'; then
  ok "check failure aborted the apply"
else
  bad "check failure was not reported (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /' | tail -n 20
fi
if [[ "$(cat "$ROOT_CHK/etc/sing-box-jp/config.json")" == "OLD-CONFIG" \
   && "$(cat "$ROOT_CHK/usr/local/bin/sing-box")" == "OLD-BIN" ]]; then
  ok "check failure did not replace existing config or binary"
else
  bad "check failure overwrote existing files"
fi
if printf '%s\n' "$out" | grep -q 'Nothing was replaced\|config was not replaced\|leaving the host unchanged'; then
  ok "check failure reported that nothing was replaced"
else
  # The die message is "Nothing was replaced." — also rollback may say no config rollback needed
  if printf '%s\n' "$out" | grep -q 'Nothing was replaced'; then
    ok "check failure reported that nothing was replaced"
  else
    bad "check failure did not clearly report that files were left alone"
  fi
fi

section "start failure rolls back previous files and service state"
ROOT_RB="$WORKDIR/root-rollback"
mkdir -p "$ROOT_RB/etc/sing-box-jp" "$ROOT_RB/usr/local/bin" "$ROOT_RB/etc/systemd/system"
printf 'OLD-CONFIG\n' > "$ROOT_RB/etc/sing-box-jp/config.json"
chmod 600 "$ROOT_RB/etc/sing-box-jp/config.json"
cat > "$ROOT_RB/etc/systemd/system/sing-box-jp.service" <<'UNIT'
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box-jp/config.json
UNIT
printf 'OLD-BIN\n' > "$ROOT_RB/usr/local/bin/sing-box"
chmod 755 "$ROOT_RB/usr/local/bin/sing-box"
printf 'active\n' > "$STATE/active"
printf 'enabled\n' > "$STATE/enabled"
: > "$STATE/log"
touch "$STATE/fail-start"
set +e
out="$(common_apply --dest-root "$ROOT_RB" --backup-dir "$ROOT_RB/var/backups/proxy" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'rolling back'; then
  ok "start failure triggered rollback"
else
  bad "start failure did not trigger rollback (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /' | tail -n 40
fi
if [[ "$(cat "$ROOT_RB/etc/sing-box-jp/config.json")" == "OLD-CONFIG" ]]; then
  ok "rollback restored the previous config"
else
  bad "config was not restored (file may still be the new one)"
fi
if [[ "$(cat "$ROOT_RB/usr/local/bin/sing-box")" == "OLD-BIN" ]]; then
  ok "rollback restored the previous binary"
else
  bad "binary was not restored"
fi
if grep -q 'ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box-jp/config.json' "$ROOT_RB/etc/systemd/system/sing-box-jp.service"; then
  # After rollback the old unit content should be back. New unit is the full template,
  # old unit was the short stub. Check that the file matches the stub (one ExecStart block only).
  if [[ "$(wc -l < "$ROOT_RB/etc/systemd/system/sing-box-jp.service")" -le 5 ]]; then
    ok "rollback restored the previous unit file"
  else
    bad "unit file still looks like the new template"
  fi
else
  bad "unit file missing expected ExecStart after rollback"
fi
if printf '%s\n' "$out" | grep -q 'restored .*/config.json from backup' \
   && printf '%s\n' "$out" | grep -q 'restored .*/sing-box from backup'; then
  ok "rollback report listed restored config and binary"
else
  bad "rollback report was incomplete"
  printf '%s\n' "$out" | sed -n '/rolling back/,$p' | sed 's/^/    /'
fi
# Service was active and start failed; rollback should try to start the old service.
if printf '%s\n' "$out" | grep -q 'restarted sing-box-jp.service (was active)'; then
  ok "rollback attempted to restore the previously active service"
else
  bad "rollback did not report restoring the previously active service"
fi
after_rb="$(snapshot)"
if [[ "$before" == "$after_rb" ]]; then
  ok "rollback test did not change host proxy paths"
else
  bad "rollback test leaked writes onto the host"
fi

printf '\n---- test-deploy summary: %s passed, %s failed ----\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
