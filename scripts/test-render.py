#!/usr/bin/env python3
"""Offline tests for topology rendering, rule profiles, DNS wiring, and migration.

Uses only documentation IPv4 space and dummy keys. Never prints secret values.
Does not change the real host.
"""
from __future__ import annotations

import copy
import json
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
import importlib.util

spec = importlib.util.spec_from_file_location("pdk_render", SCRIPT_DIR / "render-topology.py")
rt = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(rt)

PASS = 0
FAIL = 0


def ok(name: str) -> None:
    global PASS
    PASS += 1
    print(f"  [PASS] {name}")


def bad(name: str, detail: str = "") -> None:
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {name}{': ' + detail if detail else ''}", file=sys.stderr)


def extract_payload(path: Path, key: str):
    return rt._extract_inline_payload(path.read_text(encoding="utf-8").splitlines(), key)


def filled_direct_topo(instance: str = "edge1"):
    return {
        "instance": instance,
        "relay": {
            "public_host": "203.0.113.50",
            "listen_port": 443,
            "ssh_port": 22,
            "vless_reality": {
                "enabled": True,
                "server_name": "www.cloudflare.com",
                "private_key": "A" * 43,
                "public_key": "B" * 43,
                "short_id": "aabbccdd",
            },
            "hysteria2": {"enabled": False},
        },
        "exits": [
            {
                "id": "local-out",
                "label": "本机直出",
                "type": "direct",
                "vless_uuid": "00000000-0000-4000-8000-000000000001",
                "allow_udp": True,
                "groups": ["正常代理"],
            }
        ],
        "clients": {"rule_profile": "default"},
    }


def filled_multi_topo(instance: str = "hub-a"):
    topo = filled_direct_topo(instance)
    topo["exits"] = [
        {
            "id": "local-out",
            "label": "本机直出",
            "type": "direct",
            "vless_uuid": "00000000-0000-4000-8000-000000000001",
            "allow_udp": True,
            "groups": ["正常代理"],
        },
        {
            "id": "line-http",
            "label": "专线 HTTP",
            "type": "http",
            "vless_uuid": "00000000-0000-4000-8000-000000000002",
            "allow_udp": False,
            "server_resolve": False,
            "groups": ["正常代理", "AI-Google"],
            "upstream": {"host": "198.51.100.20", "port": 3128, "username": "u-test", "password": "p-test"},
        },
        {
            "id": "line-socks",
            "label": "SOCKS 落地",
            "type": "socks",
            "vless_uuid": "00000000-0000-4000-8000-000000000003",
            "allow_udp": True,
            "groups": ["正常代理"],
            "upstream": {"host": "198.51.100.30", "port": 1080},
        },
        {
            "id": "home-wg",
            "label": "家宽隧道",
            "type": "wireguard",
            "vless_uuid": "00000000-0000-4000-8000-000000000004",
            "ip_strategy": "ipv4_only",
            "dns_detour": True,
            "allow_udp": False,
            "groups": ["正常代理", "AI-Google"],
            "upstream": {
                "local_ipv4": "10.77.0.2/32",
                "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "peer_host": "198.51.100.88",
                "peer_port": 51820,
                "peer_public_key": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
            },
        },
    ]
    return topo


def test_legacy_sets_frozen():
    fl = REPO_ROOT / "legacy" / "flclash-strict.template.yaml"
    google = extract_payload(fl, "google-extra")
    cn = extract_payload(fl, "cn-allowlist")
    if len(google) != 29:
        bad("legacy google-extra count", f"got {len(google)}")
    else:
        ok("legacy google-extra still has 29 entries")
    if len(cn) != 1199:
        bad("legacy cn-allowlist count", f"got {len(cn)}")
    else:
        ok("legacy cn-allowlist still has 1199 entries")

    prof_g = rt._read_rule_list(REPO_ROOT / "rules/profiles/cn-strict/google-extra.list")
    prof_c = rt._read_rule_list(REPO_ROOT / "rules/profiles/cn-strict/cn-direct.list")

    def keys(items):
        out = set()
        for item in items:
            kind, target, _payload = rt._normalize_domain_entry(item)
            out.add(f"{kind},{target.lower()}")
        return out

    missing_g = keys(google) - keys(prof_g)
    missing_c = keys(cn) - keys(prof_c)
    if missing_g:
        bad("cn-strict google-extra lost legacy entries", f"{len(missing_g)} missing")
    else:
        ok("cn-strict google-extra keeps the full legacy set")
    if missing_c:
        bad("cn-strict cn-direct lost legacy entries", f"{len(missing_c)} missing")
    else:
        ok("cn-strict cn-direct keeps the full legacy set")
    return keys(google), keys(cn)


def test_single_and_multi():
    with tempfile.TemporaryDirectory(prefix="pdk-render-") as td:
        td_path = Path(td)
        one = rt.validate_and_resolve(filled_direct_topo("solo"), td_path, generate_secrets=False)
        cfg = rt.build_singbox_server_config(one)
        if len(one["exits"]) != 1 or one["exits"][0]["id"] != "local-out":
            bad("single-exit topology kept custom id")
        else:
            ok("single-exit topology uses the caller's id and label")
        if cfg["route"]["rules"][-1].get("action") != "reject":
            bad("server last route rule should reject leftover inbound traffic")
        else:
            ok("single-exit config ends inbound traffic with reject")

        multi = rt.validate_and_resolve(filled_multi_topo("hub-a"), td_path, generate_secrets=False)
        cfg2 = rt.build_singbox_server_config(multi)
        ids = [ex["id"] for ex in multi["exits"]]
        if ids != ["local-out", "line-http", "line-socks", "home-wg"]:
            bad("multi-exit ids", str(ids))
        else:
            ok("multi-exit topology keeps four custom names and types")
        types = {ex["id"]: ex["type"] for ex in multi["exits"]}
        if types["line-http"] != "http" or types["line-socks"] != "socks" or types["home-wg"] != "wireguard":
            bad("multi-exit types")
        else:
            ok("multi-exit includes direct, HTTP, SOCKS and WireGuard")

        # Renaming / count change
        renamed = filled_multi_topo("hub-b")
        renamed["exits"] = [renamed["exits"][0], renamed["exits"][3]]
        renamed["exits"][1]["id"] = "wg-alpha"
        renamed["exits"][1]["label"] = "Alpha Tunnel"
        renamed["exits"][1]["vless_uuid"] = "00000000-0000-4000-8000-000000000099"
        res = rt.validate_and_resolve(renamed, td_path, generate_secrets=False)
        cfg3 = rt.build_singbox_server_config(res)
        tags = [s.get("tag") for s in cfg3["dns"]["servers"]]
        if "dns-wg-alpha" not in tags or "dns-home-wg" in tags:
            bad("dns tags follow renamed exit ids", str(tags))
        else:
            ok("DNS tags follow renamed exit ids, not hard-coded city names")
        return cfg2


def test_placeholder_does_not_echo_secrets():
    topo = filled_direct_topo("leak1")
    topo["exits"][0] = {
        "id": "http1",
        "label": "http1",
        "type": "http",
        "vless_uuid": "00000000-0000-4000-8000-000000000001",
        "upstream": {
            "host": "<UPSTREAM_HTTP_HOST>",
            "port": 3128,
            "username": "filleduser",
            "password": "SuperSecretTestOnly_XYZ",
        },
    }
    try:
        rt.validate_and_resolve(topo, Path("/tmp"), generate_secrets=False, allow_placeholders=False)
        bad("missing placeholder should raise")
        return
    except ValueError as exc:
        msg = str(exc)
    if "SuperSecretTestOnly_XYZ" in msg or "filleduser" in msg:
        bad("placeholder error echoed a filled secret")
    elif "upstream.host" not in msg:
        bad("placeholder error should name the unfilled field", msg)
    else:
        ok("placeholder error names field paths and does not echo secret values")


def test_dns_fail_closed(cfg: dict) -> None:
    chain = [r for r in cfg["dns"]["rules"] if r.get("auth_user") == ["home-wg"]]
    servers = [s["tag"] for s in cfg["dns"]["servers"]]
    if "dns-home-wg" not in servers or "dns-home-wg-backup" not in servers:
        bad("detour DNS servers missing")
        return
    detours = [s for s in cfg["dns"]["servers"] if s["tag"] in {"dns-home-wg", "dns-home-wg-backup"}]
    if any(s.get("detour") != "exit-home-wg" for s in detours):
        bad("detour DNS servers must stay inside the exit tunnel")
    else:
        ok("in-tunnel DNS primary and backup both set detour to the exit")
    actions = [(r.get("action"), r.get("server")) for r in chain]
    ev = [r for r in chain if r.get("action") == "evaluate"]
    if not any(r.get("query_type") == ["AAAA"] and r.get("action") == "reject" for r in chain):
        bad("ipv4_only detour should reject AAAA so it cannot fall through to dns.final")
    elif not ev or ev[0].get("server") != "dns-home-wg":
        bad("dns chain should evaluate the primary first", str(actions[:4]))
    elif not any(r.get("server") == "dns-home-wg-backup" for r in ev):
        bad("dns chain does not query the backup server", str(actions))
    elif chain[-1].get("action") != "reject":
        bad("dns chain must fail-closed with reject, not fall through to final")
    elif any("strategy" in r for r in cfg["dns"]["rules"]):
        bad("DNS rules still use the deprecated action strategy option")
    else:
        ok("in-tunnel DNS evaluates primary then backup and rejects if both fail")


def test_profiles():
    with tempfile.TemporaryDirectory(prefix="pdk-prof-") as td:
        td_path = Path(td)
        default_topo = rt.validate_and_resolve(filled_direct_topo("p-default"), td_path, generate_secrets=False)
        default_bundle = rt.load_rule_bundle(default_topo, REPO_ROOT)
        clash_default = rt.build_flclash_yaml(default_topo, default_bundle)
        sr_default, _uris = rt.build_shadowrocket_conf_and_uris(default_topo, default_bundle)
        if "listen: 127.0.0.1:1053" not in clash_default or "respect-rules: true" not in clash_default:
            bad("default FlClash DNS is not in strict loopback mode")
        elif "listen: 0.0.0.0:1053" in clash_default:
            bad("default FlClash DNS listens on all interfaces")
        elif "GEOIP,CN" in clash_default or "GEOIP,CN" in sr_default or "cn-allowlist" in clash_default:
            bad("default profile must not apply China direct policy")
        else:
            ok("default profile uses loopback DNS and no China direct policy")

        cn_topo = filled_direct_topo("p-cn")
        cn_topo["clients"] = {"rule_profile": "cn-strict", "ai_group": "AI-Google", "default_group": "正常代理"}
        cn_topo = rt.validate_and_resolve(cn_topo, td_path, generate_secrets=False)
        cn_bundle = rt.load_rule_bundle(cn_topo, REPO_ROOT)
        if len(cn_bundle["google_extra"]) < 29 or len(cn_bundle["cn_direct"]) < 1199:
            bad("cn-strict bundle counts", f"g={len(cn_bundle['google_extra'])} c={len(cn_bundle['cn_direct'])}")
        else:
            ok("cn-strict bundle loads the full curated lists")
        clash_cn = rt.build_flclash_yaml(cn_topo, cn_bundle)
        sr_cn, _ = rt.build_shadowrocket_conf_and_uris(cn_topo, cn_bundle)
        checks = [
            ("listen: 127.0.0.1:1053", clash_cn),
            ("respect-rules: true", clash_cn),
            ("rule-set:google-extra,google,google-gemini,youtube", clash_cn),
            ("https://8.8.8.8/dns-query#AI-Google", clash_cn),
            ("RULE-SET,cn-allowlist,DIRECT", clash_cn),
            ("AND,((RULE-SET,google-extra),(NETWORK,UDP)),REJECT", clash_cn),
            ("GEOIP,CN,DIRECT,no-resolve", sr_cn),
            ("DOMAIN-SUFFIX,recaptcha.net,AI-Google", sr_cn),
            ("DOMAIN-SUFFIX,lingguang.com,DIRECT", sr_cn),
        ]
        missing = [item for item, blob in checks if item not in blob]
        # recaptcha is +.recaptcha.net -> DOMAIN-SUFFIX,recaptcha.net,<ai group>
        if "AND,(NETWORK,UDP),(DST-PORT,443),REJECT" in clash_cn or "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT" in clash_cn:
            bad("cn-strict must not use a global UDP/443 reject in place of Google-set rejects")
        elif missing:
            bad("cn-strict rendered clients missing expected semantics", "; ".join(missing))
        else:
            ok("cn-strict FlClash and Shadowrocket keep Google extras, CN allowlist, and Google UDP rejects")

        # payload presence in inline provider
        if "- +.recaptcha.net" not in clash_cn or "- +.lingguang.com" not in clash_cn:
            bad("cn-strict inline payloads dropped +.suffix entries")
        else:
            ok("cn-strict FlClash inline payloads keep +.suffix entries")


def test_migrator(legacy_google_keys, legacy_cn_keys):
    with tempfile.TemporaryDirectory(prefix="pdk-mig-") as td:
        root = Path(td)
        (root / "legacy").mkdir()
        (root / "rules" / "profiles" / "cn-strict").mkdir(parents=True)
        src_fl = REPO_ROOT / "legacy/flclash-strict.template.yaml"
        src_sr = REPO_ROOT / "legacy/shadowrocket.template.conf"
        (root / "legacy/flclash-strict.template.yaml").write_text(src_fl.read_text(encoding="utf-8"), encoding="utf-8")
        (root / "legacy/shadowrocket.template.conf").write_text(src_sr.read_text(encoding="utf-8"), encoding="utf-8")
        # Start from an empty profile so the migrator has to recover the full sets.
        (root / "rules/profiles/cn-strict/google-extra.list").write_text("# empty start\n", encoding="utf-8")
        (root / "rules/profiles/cn-strict/cn-direct.list").write_text("# empty start\n", encoding="utf-8")
        rc = rt.migrate_legacy_rules(root, dest_profile="cn-strict")
        if rc != 0:
            bad("migrator exit code", str(rc))
            return
        got_g = rt._read_rule_list(root / "rules/profiles/cn-strict/google-extra.list")
        got_c = rt._read_rule_list(root / "rules/profiles/cn-strict/cn-direct.list")

        def keys(items):
            out = set()
            for item in items:
                kind, target, _payload = rt._normalize_domain_entry(item)
                out.add(f"{kind},{target.lower()}")
            return out

        miss_g = legacy_google_keys - keys(got_g)
        miss_c = legacy_cn_keys - keys(got_c)
        if miss_g or miss_c:
            bad("migrator dropped legacy entries", f"google missing {len(miss_g)}, cn missing {len(miss_c)}")
        else:
            ok("migrator recovers the full FlClash payload sets into cn-strict")

        # Shadowrocket DOMAIN*,DIRECT coverage: every DIRECT domain in the legacy conf
        sr_direct = rt._extract_shadowrocket_rules(src_sr.read_text(encoding="utf-8"), policy="DIRECT")
        sr_keys = {f"{k},{t.lower()}" for k, t, _p in sr_direct}
        # lan/local are DIRECT too
        miss_sr = sr_keys - keys(got_c)
        if miss_sr:
            bad("migrator missed Shadowrocket DIRECT domains", f"{len(miss_sr)} missing")
        else:
            ok(f"migrator reads Shadowrocket DOMAIN*/DIRECT ({len(sr_keys)} entries)")

        # Synthetic payload-only file
        synth = root / "legacy" / "extra.yaml"
        # Already migrated; add a new source by appending a one-off template
        extra_root = Path(td) / "extra"
        (extra_root / "legacy").mkdir(parents=True)
        (extra_root / "rules/profiles/cn-strict").mkdir(parents=True)
        (extra_root / "legacy/flclash-strict.template.yaml").write_text(
            "rule-providers:\n  google-extra:\n    type: inline\n    behavior: domain\n    payload:\n    - +.example-migrate.test\n  cn-allowlist:\n    type: inline\n    behavior: domain\n    payload:\n    - +.payload-only.example\n",
            encoding="utf-8",
        )
        (extra_root / "legacy/shadowrocket.template.conf").write_text(
            "[Rule]\nDOMAIN-SUFFIX,rocket-only.example,DIRECT\nDOMAIN,exact-rocket.example,DIRECT\n",
            encoding="utf-8",
        )
        (extra_root / "rules/profiles/cn-strict/google-extra.list").write_text("", encoding="utf-8")
        (extra_root / "rules/profiles/cn-strict/cn-direct.list").write_text("", encoding="utf-8")
        rt.migrate_legacy_rules(extra_root)
        got = "\n".join(rt._read_rule_list(extra_root / "rules/profiles/cn-strict/cn-direct.list"))
        ggot = "\n".join(rt._read_rule_list(extra_root / "rules/profiles/cn-strict/google-extra.list"))
        if "payload-only.example" not in got or "rocket-only.example" not in got or "exact-rocket.example" not in got:
            bad("migrator synthetic payload/Shadowrocket parse", got)
        elif "example-migrate.test" not in ggot:
            bad("migrator synthetic google payload")
        else:
            ok("migrator parses YAML +. payloads and Shadowrocket DOMAIN* lines")


def main() -> int:
    print("==> render / rules / DNS tests")
    gkeys, ckeys = test_legacy_sets_frozen()
    cfg = test_single_and_multi()
    test_placeholder_does_not_echo_secrets()
    test_dns_fail_closed(cfg)
    test_profiles()
    test_migrator(gkeys, ckeys)
    print(f"=== render tests: PASS={PASS} FAIL={FAIL} ===")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
