#!/usr/bin/env python3
"""Universal topology compiler & interactive wizard for proxy-deploy-kit.

Compiles a single declarative topology (.yaml or .json) into synchronized:
  - sing-box 1.14+ server config.json (0600)
  - parameterized systemd unit file
  - optional self-signed Hysteria2 TLS cert/key (0600) with SHA-256 pinning
  - FlClash / Clash Meta client YAML (0600)
  - Shadowrocket client .conf (0600)
  - Shareable VLESS-Reality & Hysteria2 URI list (0600)
"""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


REPO_ROOT = Path(__file__).resolve().parent.parent
PlaceholderPattern = re.compile(r"<[A-Z0-9_]+>")


# ---------------------------------------------------------------------------
# Zero-dependency YAML subset + JSON loader / dumper
# ---------------------------------------------------------------------------

def _parse_scalar(val: str) -> Any:
    val = val.strip()
    if not val:
        return ""
    if val in ("true", "True"):
        return True
    if val in ("false", "False"):
        return False
    if val in ("null", "None", "~"):
        return None
    if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
        return val[1:-1]
    if val.startswith("[") and val.endswith("]"):
        inner = val[1:-1].strip()
        if not inner:
            return []
        return [_parse_scalar(x) for x in _split_inline_list(inner)]
    if re.fullmatch(r"-?[0-9]+", val):
        return int(val)
    return val


def _split_inline_list(s: str) -> List[str]:
    items: List[str] = []
    cur: List[str] = []
    quote: Optional[str] = None
    for ch in s:
        if quote:
            cur.append(ch)
            if ch == quote:
                quote = None
        elif ch in ('"', "'"):
            quote = ch
            cur.append(ch)
        elif ch == ",":
            items.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if cur:
        items.append("".join(cur).strip())
    return items


def _strip_inline_comment(line: str) -> str:
    quote: Optional[str] = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in ('"', "'"):
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1].isspace()):
            return line[:i].rstrip()
    return line.rstrip()


def _minimal_yaml_load(text: str) -> Dict[str, Any]:
    raw_lines: List[Tuple[int, str]] = []
    for raw in text.splitlines():
        cleaned = _strip_inline_comment(raw)
        if not cleaned.strip():
            continue
        indent = len(cleaned) - len(cleaned.lstrip(" "))
        raw_lines.append((indent, cleaned.lstrip(" ")))

    def parse_block(idx: int, expected_indent: int) -> Tuple[Any, int]:
        if idx >= len(raw_lines):
            return {}, idx
        first_indent, first_content = raw_lines[idx]
        if first_indent < expected_indent:
            return {}, idx
        if first_content.startswith("- "):
            arr: List[Any] = []
            while idx < len(raw_lines):
                ind, content = raw_lines[idx]
                if ind < expected_indent or not content.startswith("- "):
                    break
                if ind > expected_indent:
                    raise ValueError(f"Unexpected list indentation at: {content}")
                rest = content[2:].strip()
                idx += 1
                if not rest:
                    sub, idx = parse_block(idx, expected_indent + 2)
                    arr.append(sub)
                elif ":" in rest and not (rest.startswith('"') or rest.startswith("'")):
                    k, v = rest.split(":", 1)
                    item_dict: Dict[str, Any] = {}
                    k = k.strip()
                    v = v.strip()
                    if v:
                        item_dict[k] = _parse_scalar(v)
                    else:
                        sub, idx = parse_block(idx, expected_indent + 4)
                        item_dict[k] = sub
                    while idx < len(raw_lines) and raw_lines[idx][0] >= expected_indent + 2:
                        sub_ind, sub_c = raw_lines[idx]
                        if sub_c.startswith("- ") and sub_ind == expected_indent:
                            break
                        sk, sv = sub_c.split(":", 1)
                        sk = sk.strip()
                        sv = sv.strip()
                        idx += 1
                        if sv:
                            item_dict[sk] = _parse_scalar(sv)
                        else:
                            sub_val, idx = parse_block(idx, sub_ind + 2)
                            item_dict[sk] = sub_val
                    arr.append(item_dict)
                else:
                    arr.append(_parse_scalar(rest))
            return arr, idx
        else:
            mapping: Dict[str, Any] = {}
            while idx < len(raw_lines):
                ind, content = raw_lines[idx]
                if ind < expected_indent:
                    break
                if content.startswith("- ") and ind == expected_indent:
                    break
                if ":" not in content:
                    raise ValueError(f"Expected key: value at: {content}")
                k, v = content.split(":", 1)
                k = k.strip()
                v = v.strip()
                idx += 1
                if v:
                    mapping[k] = _parse_scalar(v)
                else:
                    if idx < len(raw_lines) and raw_lines[idx][0] > ind:
                        sub, idx = parse_block(idx, raw_lines[idx][0])
                        mapping[k] = sub
                    else:
                        mapping[k] = {}
            return mapping, idx

    parsed, _ = parse_block(0, 0)
    if not isinstance(parsed, dict):
        raise ValueError("Top-level topology must be a mapping/object")
    return parsed


def load_topology_file(path: Path) -> Dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".json" or text.lstrip().startswith("{"):
        return json.loads(text)
    try:
        import yaml  # type: ignore
        data = yaml.safe_load(text)
        if isinstance(data, dict):
            return data
    except ImportError:
        pass
    return _minimal_yaml_load(text)


def dump_yaml_or_json(data: Dict[str, Any], as_json: bool = False) -> str:
    if as_json:
        return json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    try:
        import yaml  # type: ignore
        return yaml.safe_dump(data, sort_keys=False, allow_unicode=True)
    except ImportError:
        return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def write_secret_file(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, content.encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(path, mode)


# ---------------------------------------------------------------------------
# Cryptographic Secret & Certificate Helpers
# ---------------------------------------------------------------------------

def generate_reality_keypair() -> Tuple[str, str]:
    """Generate X25519 Reality private_key and public_key (URL-safe base64, unpadded)."""
    sb = shutil.which("sing-box")
    if sb:
        proc = subprocess.run(
            [sb, "generate", "reality-keypair"],
            capture_output=True, text=True, check=False
        )
        if proc.returncode == 0:
            priv = pub = ""
            for line in proc.stdout.splitlines():
                if "PrivateKey:" in line:
                    priv = line.split(":", 1)[1].strip()
                elif "PublicKey:" in line:
                    pub = line.split(":", 1)[1].strip()
            if priv and pub:
                return priv, pub

    try:
        from cryptography.hazmat.primitives import serialization  # type: ignore
        from cryptography.hazmat.primitives.asymmetric import x25519  # type: ignore
        priv_obj = x25519.X25519PrivateKey.generate()
        priv_raw = priv_obj.private_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PrivateFormat.Raw,
            encryption_algorithm=serialization.NoEncryption(),
        )
        pub_raw = priv_obj.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        priv_b64 = base64.urlsafe_b64encode(priv_raw).decode("ascii").rstrip("=")
        pub_b64 = base64.urlsafe_b64encode(pub_raw).decode("ascii").rstrip("=")
        return priv_b64, pub_b64
    except Exception:
        pass

    with tempfile.TemporaryDirectory() as td:
        key_pem = Path(td) / "x25519.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "X25519", "-out", str(key_pem)], check=True, capture_output=True)
        priv_der = subprocess.run(
            ["openssl", "pkey", "-in", str(key_pem), "-outform", "DER"],
            check=True, capture_output=True
        ).stdout
        pub_der = subprocess.run(
            ["openssl", "pkey", "-in", str(key_pem), "-pubout", "-outform", "DER"],
            check=True, capture_output=True
        ).stdout
        # PKCS#8 X25519 DER ends with 32-byte raw private key; SPKI DER ends with 32-byte raw public key
        priv_b64 = base64.urlsafe_b64encode(priv_der[-32:]).decode("ascii").rstrip("=")
        pub_b64 = base64.urlsafe_b64encode(pub_der[-32:]).decode("ascii").rstrip("=")
        return priv_b64, pub_b64


def ensure_hy2_cert_and_pin(cert_path: Path, key_path: Path, san: str, generate_if_missing: bool) -> str:
    """Generate self-signed ECDSA P-256 cert if requested/missing, and compute SHA-256 fingerprint."""
    if not cert_path.exists() or not key_path.exists():
        if not generate_if_missing:
            raise ValueError(
                f"Hysteria2 cert/key not found at {cert_path} / {key_path} "
                f"(pass --generate-secrets or provide cert_pin_sha256)"
            )
        cert_path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "openssl", "req", "-x509",
                "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                "-days", "3650", "-nodes",
                "-subj", f"/CN={san}",
                "-addext", f"subjectAltName=DNS:{san}",
                "-keyout", str(key_path),
                "-out", str(cert_path),
            ],
            check=True,
            capture_output=True,
        )
        os.chmod(key_path, 0o600)
        os.chmod(cert_path, 0o600)

    der = subprocess.run(
        ["openssl", "x509", "-in", str(cert_path), "-outform", "DER"],
        check=True, capture_output=True
    ).stdout
    digest = hashlib.sha256(der).hexdigest().upper()
    return ":".join(digest[i:i + 2] for i in range(0, len(digest), 2))


# ---------------------------------------------------------------------------
# Topology Validation & Secret Resolution
# ---------------------------------------------------------------------------


def _placeholder_field_paths(obj: Any, prefix: str) -> List[str]:
    """Return dotted field names that still contain <PLACEHOLDER> tokens. Never include values."""
    found: List[str] = []
    if isinstance(obj, dict):
        for key, val in obj.items():
            found.extend(_placeholder_field_paths(val, f"{prefix}.{key}"))
    elif isinstance(obj, list):
        for idx, val in enumerate(obj):
            found.extend(_placeholder_field_paths(val, f"{prefix}[{idx}]"))
    elif isinstance(obj, str) and PlaceholderPattern.search(obj):
        found.append(prefix)
    return found


def _unfilled_placeholder_error(scope: str, obj: Any, prefix: str) -> ValueError:
    fields = _placeholder_field_paths(obj, prefix)
    if not fields:
        return ValueError(f"Unfilled placeholder in {scope}")
    return ValueError(f"Unfilled placeholder in {scope}: {', '.join(fields)}")


def _dns_failover_chain(auth_user: str, primary: str, backup: str, strategy: str, fail_closed: bool) -> List[Dict[str, Any]]:
    """Primary then in-path backup. fail_closed=True rejects instead of falling through to dns.final.

    sing-box 1.14 rejects the legacy DNS rule action `strategy` option when evaluate/match_response
    is used. ipv4_only / ipv6_only are expressed as rule items: unmatched query types are rejected
    so they cannot fall through to dns.final.
    """
    ev_primary: Dict[str, Any] = {
        "auth_user": [auth_user],
        "action": "evaluate",
        "server": primary,
        "timeout": "6s",
    }
    ev_backup: Dict[str, Any] = {
        "auth_user": [auth_user],
        "action": "evaluate",
        "server": backup,
        "timeout": "4s",
    }
    prelude: List[Dict[str, Any]] = []
    match_extra: Dict[str, Any] = {}
    if strategy == "ipv4_only":
        prelude.append({"auth_user": [auth_user], "query_type": ["AAAA"], "action": "reject"})
        match_extra["ip_version"] = 4
    elif strategy == "ipv6_only":
        prelude.append({"auth_user": [auth_user], "query_type": ["A"], "action": "reject"})
        match_extra["ip_version"] = 6

    def with_match(rule: Dict[str, Any]) -> Dict[str, Any]:
        merged = dict(rule)
        merged.update(match_extra)
        return merged

    rules: List[Dict[str, Any]] = list(prelude)
    rules.append(with_match(ev_primary))
    for rcode in ("NOERROR", "NXDOMAIN"):
        rules.append(with_match({
            "auth_user": [auth_user],
            "match_response": True,
            "response_rcode": rcode,
            "action": "respond",
        }))
    rules.append(with_match(ev_backup))
    for rcode in ("NOERROR", "NXDOMAIN"):
        rules.append(with_match({
            "auth_user": [auth_user],
            "match_response": True,
            "response_rcode": rcode,
            "action": "respond",
        }))
    if fail_closed:
        rules.append(with_match({"auth_user": [auth_user], "action": "reject"}))
    return rules


VALID_EXIT_TYPES = {"direct", "http", "socks", "wireguard", "vless", "shadowsocks"}
VALID_STRATEGIES = {"ipv4_only", "prefer_ipv4", "prefer_ipv6", "ipv6_only", "dual"}


def validate_and_resolve(
    topo: Dict[str, Any],
    out_dir: Path,
    generate_secrets: bool,
    allow_placeholders: bool = False,
) -> Dict[str, Any]:
    resolved = copy.deepcopy(topo)
    instance = str(resolved.get("instance", "relay")).strip()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,30}", instance):
        raise ValueError(f"Invalid instance slug '{instance}': use lowercase letters, digits, hyphens")
    resolved["instance"] = instance

    relay = resolved.setdefault("relay", {})
    public_host = str(relay.get("public_host", "")).strip()
    if not public_host:
        raise ValueError("relay.public_host is required")
    if not allow_placeholders and PlaceholderPattern.search(public_host):
        raise ValueError("Unfilled placeholder in relay.public_host")

    listen_port = relay.get("listen_port", 443)
    if not isinstance(listen_port, int) or not (1 <= listen_port <= 65535):
        raise ValueError(f"relay.listen_port must be an integer 1..65535, got: {listen_port!r}")
    relay["listen_port"] = listen_port
    relay["listen"] = str(relay.get("listen", "::"))
    relay["ssh_port"] = int(relay.get("ssh_port", 22))
    relay["log_level"] = str(relay.get("log_level", "warn"))

    vless = relay.setdefault("vless_reality", {"enabled": True})
    vless_enabled = bool(vless.get("enabled", True))
    vless["enabled"] = vless_enabled
    if vless_enabled:
        vless.setdefault("server_name", "www.cloudflare.com")
        vless["handshake_port"] = int(vless.get("handshake_port", 443))
        priv = str(vless.get("private_key", "auto"))
        pub = str(vless.get("public_key", "auto"))
        sid = str(vless.get("short_id", "auto"))
        if priv == "auto" or pub == "auto":
            if not generate_secrets:
                raise ValueError("Reality keypair is set to 'auto'; pass --generate-secrets or supply keys")
            priv, pub = generate_reality_keypair()
        if sid == "auto":
            if not generate_secrets:
                raise ValueError("Reality short_id is set to 'auto'; pass --generate-secrets or supply short_id")
            sid = secrets.token_hex(8)
        vless["private_key"] = priv
        vless["public_key"] = pub
        vless["short_id"] = sid

    hy2 = relay.setdefault("hysteria2", {"enabled": True})
    hy2_enabled = bool(hy2.get("enabled", True))
    hy2["enabled"] = hy2_enabled
    if hy2_enabled:
        hy2["up_mbps"] = int(hy2.get("up_mbps", 100))
        hy2["down_mbps"] = int(hy2.get("down_mbps", 200))
        san = str(hy2.get("cert_san", "www.bing.com"))
        hy2["cert_san"] = san
        default_etc_dir = f"/etc/sing-box-{instance}"
        hy2.setdefault("cert_path", f"{default_etc_dir}/hy2.crt")
        hy2.setdefault("key_path", f"{default_etc_dir}/hy2.key")
        auto_self_signed = bool(hy2.get("auto_self_signed", True))
        hy2["auto_self_signed"] = auto_self_signed
        pin = str(hy2.get("cert_pin_sha256", "auto"))
        if pin == "auto":
            local_cert = out_dir / "server" / Path(hy2["cert_path"]).name
            local_key = out_dir / "server" / Path(hy2["key_path"]).name
            pin = ensure_hy2_cert_and_pin(local_cert, local_key, san, generate_secrets and auto_self_signed)
        hy2["cert_pin_sha256"] = pin

    if not vless_enabled and not hy2_enabled:
        raise ValueError("At least one inbound protocol (vless_reality or hysteria2) must be enabled")

    exits = resolved.get("exits")
    if not isinstance(exits, list) or not exits:
        raise ValueError("exits must be a non-empty list")

    seen_ids = set()
    for ex in exits:
        ex_id = str(ex.get("id", "")).strip()
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,31}", ex_id):
            raise ValueError(f"Invalid exit id '{ex_id}'")
        if ex_id in seen_ids:
            raise ValueError(f"Duplicate exit id '{ex_id}'")
        seen_ids.add(ex_id)
        ex["id"] = ex_id
        ex["label"] = str(ex.get("label", ex_id)).strip()

        ex_type = str(ex.get("type", "")).strip()
        if ex_type not in VALID_EXIT_TYPES:
            raise ValueError(f"Unsupported exit type '{ex_type}' on exit '{ex_id}'")

        strat = str(ex.get("ip_strategy", "ipv4_only" if ex_type == "wireguard" else "prefer_ipv4"))
        if strat not in VALID_STRATEGIES:
            raise ValueError(f"Invalid ip_strategy '{strat}' on exit '{ex_id}'")
        ex["ip_strategy"] = strat
        ex["dns_detour"] = bool(ex.get("dns_detour", ex_type == "wireguard"))
        ex["allow_udp"] = bool(ex.get("allow_udp", False))

        if "server_resolve" not in ex:
            ex["server_resolve"] = ex_type not in ("http", "socks")
        else:
            ex["server_resolve"] = bool(ex["server_resolve"])

        if vless_enabled:
            u = str(ex.get("vless_uuid", "auto"))
            if u == "auto":
                if not generate_secrets:
                    raise ValueError(f"Exit '{ex_id}' vless_uuid is 'auto'; pass --generate-secrets")
                u = str(uuid.uuid4())
            ex["vless_uuid"] = u

        if hy2_enabled:
            pw = str(ex.get("hy2_password", "auto"))
            if pw == "auto":
                if not generate_secrets:
                    raise ValueError(f"Exit '{ex_id}' hy2_password is 'auto'; pass --generate-secrets")
                pw = secrets.token_urlsafe(24)
            ex["hy2_password"] = pw

        up = ex.get("upstream", {}) or {}
        if not allow_placeholders:
            if _placeholder_field_paths(up, "upstream"):
                raise _unfilled_placeholder_error(f"exit '{ex_id}'", up, "upstream")
        if ex_type in ("http", "socks", "vless", "shadowsocks"):
            if not up.get("host") or not isinstance(up.get("port"), int):
                raise ValueError(f"Exit '{ex_id}' ({ex_type}) requires upstream.host and integer upstream.port")
        elif ex_type == "wireguard":
            for req_k in ("local_ipv4", "private_key", "peer_host", "peer_port", "peer_public_key"):
                if req_k not in up or up[req_k] in ("", None):
                    raise ValueError(f"WireGuard exit '{ex_id}' missing upstream.{req_k}")
            if not isinstance(up["peer_port"], int):
                raise ValueError(f"WireGuard exit '{ex_id}' upstream.peer_port must be an integer")

    return resolved


# ---------------------------------------------------------------------------
# Server Config & systemd Unit Builders (sing-box 1.14+)
# ---------------------------------------------------------------------------

def build_singbox_server_config(topo: Dict[str, Any]) -> Dict[str, Any]:
    instance = topo["instance"]
    relay = topo["relay"]
    exits = topo["exits"]
    vless = relay["vless_reality"]
    hy2 = relay["hysteria2"]

    # 1. DNS servers & rules
    dns_servers: List[Dict[str, Any]] = [
        {
            "type": "https",
            "tag": "direct-doh",
            "server": "1.1.1.1",
            "server_port": 443,
            "path": "/dns-query",
        },
        {
            "type": "https",
            "tag": "direct-doh-backup",
            "server": "8.8.8.8",
            "server_port": 443,
            "path": "/dns-query",
        },
    ]
    dns_rules: List[Dict[str, Any]] = []

    for ex in exits:
        ex_id = ex["id"]
        out_tag = "direct" if ex["type"] == "direct" else f"exit-{ex_id}"
        strat = ex["ip_strategy"]
        if ex["dns_detour"] and out_tag != "direct":
            dns_tag = f"dns-{ex_id}"
            dns_backup_tag = f"dns-{ex_id}-backup"
            dns_servers.append({
                "type": "tls",
                "tag": dns_tag,
                "server": "1.1.1.1",
                "server_port": 853,
                "tls": {"enabled": True, "server_name": "cloudflare-dns.com"},
                "detour": out_tag,
            })
            dns_servers.append({
                "type": "https",
                "tag": dns_backup_tag,
                "server": "9.9.9.9",
                "server_port": 443,
                "path": "/dns-query",
                "tls": {"enabled": True, "server_name": "dns.quad9.net"},
                "detour": out_tag,
            })
            dns_rules.extend(_dns_failover_chain(ex_id, dns_tag, dns_backup_tag, strat, fail_closed=True))
        else:
            dns_rules.extend(_dns_failover_chain(ex_id, "direct-doh", "direct-doh-backup", strat, fail_closed=False))

    # 2. Inbounds
    inbounds: List[Dict[str, Any]] = []
    inbound_tags: List[str] = []
    if vless["enabled"]:
        v_tag = f"{instance}-vless"
        inbound_tags.append(v_tag)
        inbounds.append({
            "type": "vless",
            "tag": v_tag,
            "listen": relay["listen"],
            "listen_port": relay["listen_port"],
            "users": [
                {"name": ex["id"], "uuid": ex["vless_uuid"], "flow": "xtls-rprx-vision"}
                for ex in exits
            ],
            "tls": {
                "enabled": True,
                "server_name": vless["server_name"],
                "reality": {
                    "enabled": True,
                    "handshake": {
                        "server": vless["server_name"],
                        "server_port": vless["handshake_port"],
                    },
                    "private_key": vless["private_key"],
                    "short_id": [vless["short_id"]],
                },
            },
        })

    if hy2["enabled"]:
        h_tag = f"{instance}-hy2"
        inbound_tags.append(h_tag)
        inbounds.append({
            "type": "hysteria2",
            "tag": h_tag,
            "listen": relay["listen"],
            "listen_port": relay["listen_port"],
            "up_mbps": hy2["up_mbps"],
            "down_mbps": hy2["down_mbps"],
            "users": [
                {"name": ex["id"], "password": ex["hy2_password"]}
                for ex in exits
            ],
            "tls": {
                "enabled": True,
                "alpn": ["h3"],
                "certificate_path": hy2["cert_path"],
                "key_path": hy2["key_path"],
            },
        })

    # 3. Outbounds & WireGuard Endpoints
    outbounds: List[Dict[str, Any]] = [{"type": "direct", "tag": "direct"}]
    endpoints: List[Dict[str, Any]] = []
    wg_tags: List[str] = []

    for ex in exits:
        ex_id = ex["id"]
        ex_type = ex["type"]
        up = ex.get("upstream", {}) or {}
        if ex_type == "direct":
            continue
        out_tag = f"exit-{ex_id}"
        if ex_type == "http":
            ob: Dict[str, Any] = {
                "type": "http",
                "tag": out_tag,
                "server": up["host"],
                "server_port": up["port"],
            }
            if up.get("username"):
                ob["username"] = str(up["username"])
            if up.get("password"):
                ob["password"] = str(up["password"])
            if up.get("tls"):
                ob["tls"] = {"enabled": True, "server_name": str(up.get("server_name", up["host"]))}
            outbounds.append(ob)
        elif ex_type == "socks":
            ob = {
                "type": "socks",
                "tag": out_tag,
                "version": "5",
                "server": up["host"],
                "server_port": up["port"],
            }
            if up.get("username"):
                ob["username"] = str(up["username"])
            if up.get("password"):
                ob["password"] = str(up["password"])
            outbounds.append(ob)
        elif ex_type == "vless":
            ob = {
                "type": "vless",
                "tag": out_tag,
                "server": up["host"],
                "server_port": up["port"],
                "uuid": str(up["uuid"]),
            }
            if up.get("flow"):
                ob["flow"] = str(up["flow"])
            tls_cfg: Dict[str, Any] = {"enabled": bool(up.get("tls", True))}
            if up.get("server_name"):
                tls_cfg["server_name"] = str(up["server_name"])
            if up.get("reality_public_key"):
                tls_cfg["utls"] = {"enabled": True, "fingerprint": "chrome"}
                tls_cfg["reality"] = {
                    "enabled": True,
                    "public_key": str(up["reality_public_key"]),
                    "short_id": str(up.get("reality_short_id", "")),
                }
            ob["tls"] = tls_cfg
            outbounds.append(ob)
        elif ex_type == "shadowsocks":
            outbounds.append({
                "type": "shadowsocks",
                "tag": out_tag,
                "server": up["host"],
                "server_port": up["port"],
                "method": str(up.get("method", "2022-blake3-aes-128-gcm")),
                "password": str(up["password"]),
            })
        elif ex_type == "wireguard":
            wg_tags.append(out_tag)
            local_addr = [str(up["local_ipv4"])]
            if "/" not in local_addr[0]:
                local_addr[0] += "/32"
            if up.get("local_ipv6") and ex["ip_strategy"] != "ipv4_only":
                local_addr.append(str(up["local_ipv6"]))
            allowed_ips = ["0.0.0.0/0"]
            if ex["ip_strategy"] != "ipv4_only" and up.get("local_ipv6"):
                allowed_ips.append("::/0")
            peer_obj: Dict[str, Any] = {
                "address": str(up["peer_host"]),
                "port": int(up["peer_port"]),
                "public_key": str(up["peer_public_key"]),
                "allowed_ips": allowed_ips,
                "persistent_keepalive_interval": int(up.get("keepalive", 15)),
            }
            if up.get("pre_shared_key"):
                peer_obj["pre_shared_key"] = str(up["pre_shared_key"])
            if up.get("reserved"):
                peer_obj["reserved"] = list(up["reserved"])
            endpoints.append({
                "type": "wireguard",
                "tag": out_tag,
                "system": False,
                "mtu": int(up.get("mtu", 1280)),
                "address": local_addr,
                "private_key": str(up["private_key"]),
                "peers": [peer_obj],
            })

    # 4. Route rules (preserving strict security invariants + per-exit UDP switch)
    route_rules: List[Dict[str, Any]] = []
    udp_blocked_users = [ex["id"] for ex in exits if not ex["allow_udp"]]
    if len(udp_blocked_users) == len(exits):
        route_rules.append({"network": ["udp"], "action": "reject"})
    elif udp_blocked_users:
        route_rules.append({"auth_user": udp_blocked_users, "network": ["udp"], "action": "reject"})

    for ex in exits:
        if ex["server_resolve"]:
            r_rule: Dict[str, Any] = {"auth_user": [ex["id"]], "action": "resolve"}
            if ex["ip_strategy"] != "dual":
                r_rule["strategy"] = ex["ip_strategy"]
            route_rules.append(r_rule)

    if wg_tags:
        route_rules.append({"inbound": wg_tags, "action": "reject"})

    route_rules.append({"ip_is_private": True, "action": "reject"})

    for ex in exits:
        out_tag = "direct" if ex["type"] == "direct" else f"exit-{ex['id']}"
        route_rules.append({
            "auth_user": [ex["id"]],
            "action": "route",
            "outbound": out_tag,
        })

    route_rules.append({"inbound": inbound_tags, "action": "reject"})

    server_cfg: Dict[str, Any] = {
        "log": {"level": relay["log_level"], "timestamp": True},
        "dns": {
            "servers": dns_servers,
            "rules": dns_rules,
            "final": "direct-doh",
            "strategy": "prefer_ipv4",
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "rules": route_rules,
            "final": "direct",
            "default_domain_resolver": "direct-doh",
        },
    }
    if endpoints:
        server_cfg["endpoints"] = endpoints
    return server_cfg


def render_systemd_unit(instance: str, bin_dest: str = "/usr/local/bin/sing-box", config_dest: Optional[str] = None) -> str:
    unit_name = f"sing-box-{instance}"
    cfg_dest = config_dest or f"/etc/sing-box-{instance}/config.json"
    tpl_path = REPO_ROOT / "server" / "sing-box.service.template"
    tpl = tpl_path.read_text(encoding="utf-8")
    return (
        tpl.replace("__UNIT_NAME__", unit_name)
        .replace("__BIN_DEST__", bin_dest)
        .replace("__CONFIG_DEST__", cfg_dest)
    )


# ---------------------------------------------------------------------------
# Client Rules Loader & Client Config Builders (FlClash / Shadowrocket / URIs)
# ---------------------------------------------------------------------------


def _read_rule_list(file_path: Path, excludes: Optional[set] = None) -> List[str]:
    """Read a domain list. Blank lines and comments are ignored. Order is preserved. Duplicates are dropped."""
    out: List[str] = []
    seen = set()
    if not file_path.exists():
        return out
    for raw in file_path.read_text(encoding="utf-8").splitlines():
        line = _strip_inline_comment(raw).strip()
        if not line:
            continue
        key = line.lower()
        if key in seen:
            continue
        if excludes:
            kind, target, _payload = _normalize_domain_entry(line)
            t_low = target.lower()
            if any(t_low == ex or t_low.endswith("." + ex) for ex in excludes):
                continue
        seen.add(key)
        out.append(line)
    return out


def _normalize_domain_entry(item: str) -> Tuple[str, str, str]:
    """Return (kind, target, payload) for a list line.

    Payload is the form used in Clash inline domain providers ( +.suffix or an exact name ).
    """
    item = item.strip()
    if "," in item and item.split(",", 1)[0].upper() in {
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD",
    }:
        parts = [p.strip() for p in item.split(",")]
        kind, target = parts[0].upper(), parts[1]
        if kind == "DOMAIN-SUFFIX":
            payload = target if target.startswith("+.") else "+." + target.lstrip(".")
        else:
            payload = target
        return kind, target.lstrip("."), payload
    if item.startswith("+."):
        return "DOMAIN-SUFFIX", item[2:], item
    if item.startswith("*."):
        return "DOMAIN-SUFFIX", item[2:], "+." + item[2:]
    if item.startswith("."):
        return "DOMAIN-SUFFIX", item[1:], "+." + item[1:]
    return "DOMAIN", item, item


def _as_clash_rule(item: str, policy: str) -> str:
    kind, target, _payload = _normalize_domain_entry(item)
    return f"{kind},{target},{policy}"


def _as_payload(item: str) -> str:
    _kind, _target, payload = _normalize_domain_entry(item)
    return payload


def _load_exclude_set(profile_dir: Path) -> set:
    excl: set = set()
    path = profile_dir / "global-exclude.list"
    if not path.exists():
        return excl
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = _strip_inline_comment(raw).strip().lower().lstrip(".")
        if line.startswith("+."):
            line = line[2:]
        if line:
            excl.add(line)
    return excl


def load_rule_bundle(
    topo: Dict[str, Any],
    repo_root: Path,
    rules_dir: Optional[Path] = None,
) -> Dict[str, Any]:
    clients_cfg = topo.get("clients", {}) or {}
    profile = str(clients_cfg.get("rule_profile", "default")).strip() or "default"
    if rules_dir is not None:
        profile_dir = Path(rules_dir)
        profile_name = profile_dir.name
    elif profile.startswith("/") or profile.startswith(".") or "/" in profile:
        candidate = Path(profile)
        profile_dir = candidate if candidate.is_absolute() else (repo_root / candidate)
        profile_name = profile_dir.name
    else:
        profile_dir = repo_root / "rules" / "profiles" / profile
        profile_name = profile
    profile_dir = profile_dir.resolve()
    if not profile_dir.is_dir():
        raise ValueError(f"Unknown rule profile '{profile}': directory not found")

    excludes = _load_exclude_set(profile_dir)
    google_extra = _read_rule_list(profile_dir / "google-extra.list")
    if (profile_dir / "cn-direct.list").exists():
        cn_direct = _read_rule_list(profile_dir / "cn-direct.list", excludes=excludes)
    else:
        cn_direct = _read_rule_list(profile_dir / "direct.list", excludes=excludes)

    ai_services: List[str] = []
    if bool(clients_cfg.get("include_ai_services", False)):
        ai_services = _read_rule_list(repo_root / "rules" / "optional" / "ai-services.list")
    for extra in clients_cfg.get("extra_rule_files") or []:
        ai_services.extend(_read_rule_list(repo_root / str(extra) if not Path(str(extra)).is_absolute() else Path(str(extra))))

    use_cn_direct = profile_name == "cn-strict" or bool(clients_cfg.get("china_direct", False))
    return {
        "profile": profile_name,
        "profile_dir": profile_dir,
        "google_extra": google_extra,
        "cn_direct": cn_direct,
        "ai_services": ai_services,
        "use_cn_direct": use_cn_direct,
        "rule_mode": str(clients_cfg.get("rule_mode", "inline")),
    }


def load_rule_entries(rules_dir: Path) -> Tuple[List[str], List[str]]:
    """Backward-compatible loader used by older tests: returns (ai_rules, cn_rules) as kind,target pairs."""
    fake_topo = {"clients": {"rule_profile": Path(rules_dir).name}}
    bundle = load_rule_bundle(fake_topo, Path(rules_dir).parent.parent if Path(rules_dir).name in {"default", "cn-strict"} else Path(rules_dir), rules_dir=Path(rules_dir))
    def as_pairs(items: List[str]) -> List[str]:
        out = []
        for item in items:
            kind, target, _payload = _normalize_domain_entry(item)
            out.append(f"{kind},{target}")
        return out
    ai = as_pairs(bundle["google_extra"] + bundle["ai_services"])
    cn = as_pairs(bundle["cn_direct"])
    return ai, cn


def _build_policy_groups(topo: Dict[str, Any], all_node_names: List[str], exit_nodes_map: Dict[str, List[str]]) -> Tuple[str, str, List[Dict[str, Any]]]:
    clients_cfg = topo.get("clients", {}) or {}
    default_group = str(clients_cfg.get("default_group", "正常代理"))
    ai_group = str(clients_cfg.get("ai_group", "AI-Google"))
    raw_groups = clients_cfg.get("policy_groups")

    if not raw_groups:
        raw_groups = [
            {"name": default_group, "type": "select", "include_direct": True},
            {"name": ai_group, "type": "select", "include_direct": False},
        ]

    resolved_groups: List[Dict[str, Any]] = []
    for g in raw_groups:
        g_name = str(g["name"])
        g_type = str(g.get("type", "select"))
        inc_direct = bool(g.get("include_direct", g_name == default_group))
        matched_nodes: List[str] = []
        for ex in topo["exits"]:
            ex_groups = ex.get("groups")
            if ex_groups is None or g_name in ex_groups:
                matched_nodes.extend(exit_nodes_map.get(ex["id"], []))
        if not matched_nodes:
            matched_nodes = list(all_node_names)
        if inc_direct and "DIRECT" not in matched_nodes:
            matched_nodes.append("DIRECT")
        resolved_groups.append({"name": g_name, "type": g_type, "proxies": matched_nodes})

    return default_group, ai_group, resolved_groups


def _private_cidr_rules(policy: str = "DIRECT") -> List[str]:
    cidrs = [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
    ]
    return [f"IP-CIDR,{c},{policy},no-resolve" for c in cidrs]


def _flclash_dns_block(bundle: Dict[str, Any], default_group: str, ai_group: str) -> List[str]:
    use_cn = bool(bundle.get("use_cn_direct"))
    if use_cn:
        default_ns = ["223.5.5.5", "119.29.29.29"]
        proxy_ns = ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"]
    else:
        default_ns = ["1.1.1.1", "8.8.8.8"]
        proxy_ns = ["https://1.1.1.1/dns-query", "https://9.9.9.9/dns-query"]
    lines = [
        "dns:",
        "  enable: true",
        "  listen: 127.0.0.1:1053",
        "  ipv6: false",
        "  prefer-h3: false",
        "  respect-rules: true",
        "  use-hosts: true",
        "  use-system-hosts: true",
        "  enhanced-mode: fake-ip",
        "  fake-ip-range: 198.18.0.1/16",
        "  fake-ip-filter:",
        "  - +.lan",
        "  - +.local",
        "  default-nameserver:",
    ]
    for ns in default_ns:
        lines.append(f"  - {ns}")
    lines.append("  proxy-server-nameserver:")
    for ns in proxy_ns:
        lines.append(f"  - {ns}")
    lines.extend([
        "  nameserver:",
        f"  - https://1.1.1.1/dns-query#{default_group}",
        f"  - https://9.9.9.9/dns-query#{default_group}",
        "  nameserver-policy:",
    ])
    if use_cn or bundle.get("google_extra"):
        lines.append(f'    "rule-set:google-extra,google,google-gemini,youtube":')
        lines.append(f"    - https://8.8.8.8/dns-query#{ai_group}")
        lines.append(f"    - https://8.8.4.4/dns-query#{ai_group}")
    if use_cn:
        lines.append('    "rule-set:cn-allowlist,private":')
        lines.append("    - https://223.5.5.5/dns-query#DIRECT")
        lines.append("    - https://1.12.12.12/dns-query#DIRECT")
    else:
        lines.append('    "rule-set:private":')
        lines.append("    - system")
    lines.extend([
        '    "+.lan": system',
        '    "+.local": system',
        "  fallback: []",
    ])
    return lines


def _flclash_rule_providers(bundle: Dict[str, Any], ai_group: str) -> List[str]:
    lines = ["rule-providers:"]
    if bundle.get("google_extra") or bundle.get("use_cn_direct"):
        lines.extend([
            "  google-extra:",
            "    type: inline",
            "    behavior: domain",
            "    payload:",
        ])
        for item in bundle.get("google_extra") or []:
            lines.append(f"    - {_as_payload(item)}")
        # Remote Google/YouTube sets, downloaded via the AI group so the client does not leak the request.
        for name, slug in (
            ("google", "google"),
            ("google-gemini", "google-gemini"),
            ("youtube", "youtube"),
        ):
            lines.extend([
                f"  {name}:",
                "    type: http",
                "    behavior: domain",
                "    format: mrs",
                f"    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/{slug}.mrs",
                f"    path: ./ruleset/{slug}.mrs",
                "    interval: 86400",
                f"    proxy: {ai_group}",
            ])
    lines.extend([
        "  private:",
        "    type: http",
        "    behavior: domain",
        "    format: mrs",
        "    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/private.mrs",
        "    path: ./ruleset/private.mrs",
        "    interval: 86400",
        f"    proxy: {ai_group}",
        "  private-ip:",
        "    type: http",
        "    behavior: ipcidr",
        "    format: mrs",
        "    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/private.mrs",
        "    path: ./ruleset/private-ip.mrs",
        "    interval: 86400",
        f"    proxy: {ai_group}",
    ])
    if bundle.get("use_cn_direct"):
        lines.extend([
            "  cn-allowlist:",
            "    type: inline",
            "    behavior: domain",
            "    payload:",
        ])
        for item in bundle.get("cn_direct") or []:
            lines.append(f"    - {_as_payload(item)}")
        lines.extend([
            "  cncidr:",
            "    type: http",
            "    behavior: ipcidr",
            "    format: yaml",
            "    url: https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/cncidr.txt",
            "    path: ./ruleset/cncidr.yaml",
            "    interval: 86400",
            f"    proxy: {ai_group}",
        ])
    return lines


def build_flclash_yaml(topo: Dict[str, Any], bundle: Dict[str, Any]) -> str:
    relay = topo["relay"]
    vless = relay["vless_reality"]
    hy2 = relay["hysteria2"]
    clients_cfg = topo.get("clients", {}) or {}
    mixed_port = int(clients_cfg.get("mixed_port", 7890))
    enable_tun = bool(clients_cfg.get("enable_tun", True))
    host = relay["public_host"]
    port = relay["listen_port"]

    all_node_names: List[str] = []
    exit_nodes_map: Dict[str, List[str]] = {}
    proxy_blocks: List[str] = []

    for ex in topo["exits"]:
        ex_nodes: List[str] = []
        udp_str = "true" if ex["allow_udp"] else "false"
        if vless["enabled"]:
            n_vless = f"{ex['label']} - VLESS"
            ex_nodes.append(n_vless)
            all_node_names.append(n_vless)
            proxy_blocks.append(
                f'  - name: "{n_vless}"\n'
                f'    type: vless\n'
                f'    server: "{host}"\n'
                f'    port: {port}\n'
                f'    uuid: "{ex["vless_uuid"]}"\n'
                f'    network: tcp\n'
                f'    tls: true\n'
                f'    udp: {udp_str}\n'
                f'    flow: xtls-rprx-vision\n'
                f'    servername: "{vless["server_name"]}"\n'
                f'    client-fingerprint: chrome\n'
                f'    reality-opts:\n'
                f'      public-key: "{vless["public_key"]}"\n'
                f'      short-id: "{vless["short_id"]}"'
            )
        if hy2["enabled"]:
            n_hy2 = f"{ex['label']} - HY2"
            ex_nodes.append(n_hy2)
            all_node_names.append(n_hy2)
            proxy_blocks.append(
                f'  - name: "{n_hy2}"\n'
                f'    type: hysteria2\n'
                f'    server: "{host}"\n'
                f'    port: {port}\n'
                f'    password: "{ex["hy2_password"]}"\n'
                f'    sni: "{hy2["cert_san"]}"\n'
                f'    skip-cert-verify: false\n'
                f'    fingerprint: "{hy2["cert_pin_sha256"]}"\n'
                f'    udp: {udp_str}\n'
                f'    up: "{hy2["up_mbps"]} Mbps"\n'
                f'    down: "{hy2["down_mbps"]} Mbps"'
            )
        exit_nodes_map[ex["id"]] = ex_nodes

    default_group, ai_group, groups = _build_policy_groups(topo, all_node_names, exit_nodes_map)
    group_names = {g["name"] for g in groups}
    target_ai = ai_group if ai_group in group_names else default_group
    use_cn = bool(bundle.get("use_cn_direct"))

    lines: List[str] = [
        "# Generated by proxy-deploy-kit/scripts/render-topology.py",
        f"# rule_profile: {bundle.get('profile', 'default')}",
        f"mixed-port: {mixed_port}",
        "allow-lan: false",
        "bind-address: 127.0.0.1",
        "mode: rule",
        "log-level: warning",
        "ipv6: false",
        "unified-delay: true",
        "tcp-concurrent: true",
        "find-process-mode: always",
        "profile:",
        "  store-selected: true",
        "",
    ]
    lines.extend(_flclash_dns_block(bundle, default_group, target_ai))
    lines.append("")
    lines.append("proxies:")
    lines.extend(proxy_blocks)
    lines.append("")
    lines.append("proxy-groups:")
    for g in groups:
        lines.append(f'  - name: "{g["name"]}"')
        lines.append(f'    type: {g["type"]}')
        lines.append("    proxies:")
        for p in g["proxies"]:
            lines.append(f'      - "{p}"')

    lines.append("")
    lines.extend(_flclash_rule_providers(bundle, target_ai))
    lines.append("")
    lines.append("rules:")
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+", str(host)):
        lines.append(f"  - IP-CIDR,{host}/32,DIRECT,no-resolve")
    lines.append("  - DOMAIN-SUFFIX,lan,DIRECT")
    lines.append("  - DOMAIN-SUFFIX,local,DIRECT")
    for rule in _private_cidr_rules("DIRECT"):
        lines.append(f"  - {rule}")
    lines.append("  - RULE-SET,private,DIRECT")
    lines.append("  - RULE-SET,private-ip,DIRECT,no-resolve")
    if bundle.get("google_extra") or use_cn:
        for rs in ("google-extra", "google", "google-gemini", "youtube"):
            lines.append(f"  - AND,((RULE-SET,{rs}),(NETWORK,UDP)),REJECT")
            lines.append(f"  - RULE-SET,{rs},{target_ai}")
    for item in bundle.get("ai_services") or []:
        lines.append(f"  - {_as_clash_rule(item, target_ai)}")
    if use_cn:
        lines.append("  - RULE-SET,cn-allowlist,DIRECT")
        lines.append("  - RULE-SET,cncidr,DIRECT,no-resolve")
    else:
        for item in bundle.get("cn_direct") or []:
            kind, target, _payload = _normalize_domain_entry(item)
            if target.lower() in {"lan", "local"}:
                continue
            lines.append(f"  - {_as_clash_rule(item, 'DIRECT')}")
    lines.extend([
        f"  - NETWORK,UDP,{default_group}",
        "  - NETWORK,UDP,REJECT",
        f"  - MATCH,{default_group}",
    ])

    if enable_tun:
        lines.extend([
            "",
            "sniffer:",
            "  enable: true",
            "  force-dns-mapping: true",
            "  parse-pure-ip: true",
            "  override-destination: false",
            "  sniff:",
            "    HTTP:",
            "      ports: [80, 8080, 8880]",
            "    TLS:",
            "      ports: [443, 8443]",
            "    QUIC:",
            "      ports: [443, 8443]",
            "  skip-dst-address:",
            "  - 127.0.0.0/8",
            "  - 10.0.0.0/8",
            "  - 172.16.0.0/12",
            "  - 192.168.0.0/16",
            "  - 169.254.0.0/16",
            "",
            "tun:",
            "  enable: true",
            "  stack: mixed",
            "  auto-route: true",
            "  auto-detect-interface: true",
            "  strict-route: true",
            "  dns-hijack:",
            "  - any:53",
            "  - tcp://any:53",
            "  route-address:",
            "  - 0.0.0.0/1",
            "  - 128.0.0.0/1",
            "  - ::/1",
            "  - 8000::/1",
        ])
    return "\n".join(lines) + "\n"


def build_shadowrocket_conf_and_uris(topo: Dict[str, Any], bundle: Dict[str, Any]) -> Tuple[str, str]:
    relay = topo["relay"]
    vless = relay["vless_reality"]
    hy2 = relay["hysteria2"]
    host = relay["public_host"]
    port = relay["listen_port"]

    all_node_names: List[str] = []
    exit_nodes_map: Dict[str, List[str]] = {}
    uris: List[str] = []

    for ex in topo["exits"]:
        ex_nodes: List[str] = []
        if vless["enabled"]:
            n_vless = f"{ex['label']} - VLESS"
            ex_nodes.append(n_vless)
            all_node_names.append(n_vless)
            q = urllib.parse.urlencode({
                "encryption": "none",
                "flow": "xtls-rprx-vision",
                "security": "reality",
                "sni": vless["server_name"],
                "fp": "chrome",
                "pbk": vless["public_key"],
                "sid": vless["short_id"],
                "type": "tcp",
            })
            uris.append(f"vless://{ex['vless_uuid']}@{host}:{port}?{q}#{urllib.parse.quote(n_vless)}")
        if hy2["enabled"]:
            n_hy2 = f"{ex['label']} - HY2"
            ex_nodes.append(n_hy2)
            all_node_names.append(n_hy2)
            q_hy2 = urllib.parse.urlencode({
                "sni": hy2["cert_san"],
                "pinSHA256": hy2["cert_pin_sha256"],
                "insecure": "0",
            })
            uris.append(f"hysteria2://{urllib.parse.quote(ex['hy2_password'])}@{host}:{port}?{q_hy2}#{urllib.parse.quote(n_hy2)}")
        exit_nodes_map[ex["id"]] = ex_nodes

    default_group, ai_group, groups = _build_policy_groups(topo, all_node_names, exit_nodes_map)
    group_names = {g["name"] for g in groups}
    target_ai = ai_group if ai_group in group_names else default_group
    use_cn = bool(bundle.get("use_cn_direct"))

    conf_lines: List[str] = [
        "# Generated by proxy-deploy-kit/scripts/render-topology.py",
        f"# rule_profile: {bundle.get('profile', 'default')}",
        "[General]",
        "bypass-system = true",
        "skip-proxy = 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 100.64.0.0/10, 127.0.0.1, localhost, *.local",
        "bypass-tun = 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255/32",
        "dns-server = https://1.1.1.1/dns-query, https://9.9.9.9/dns-query",
    ]
    if use_cn:
        conf_lines.append("fallback-dns-server = https://223.5.5.5/dns-query, https://1.12.12.12/dns-query")
    else:
        conf_lines.append("fallback-dns-server = https://8.8.8.8/dns-query, https://9.9.9.9/dns-query")
    conf_lines.extend([
        "dns-fallback-system = false",
        "dns-direct-system = false",
        "dns-direct-fallback-proxy = true",
        "ipv6 = false",
        "prefer-ipv6 = false",
        "private-ip-answer = true",
        "",
        "[Proxy Group]",
    ])
    for g in groups:
        joined = ", ".join(g["proxies"])
        conf_lines.append(f"{g['name']} = {g['type']}, {joined}")

    conf_lines.append("")
    conf_lines.append("[Rule]")
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+", str(host)):
        conf_lines.append(f"IP-CIDR,{host}/32,DIRECT,no-resolve")
    conf_lines.append("DOMAIN-SUFFIX,lan,DIRECT")
    conf_lines.append("DOMAIN-SUFFIX,local,DIRECT")
    conf_lines.extend(_private_cidr_rules("DIRECT"))
    for item in bundle.get("google_extra") or []:
        conf_lines.append(_as_clash_rule(item, target_ai))
    if use_cn and bundle.get("google_extra"):
        conf_lines.extend([
            f"RULE-SET,https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Shadowrocket/Gemini/Gemini.list,{target_ai}",
            f"RULE-SET,https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Shadowrocket/Google/Google.list,{target_ai}",
            f"RULE-SET,https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Shadowrocket/YouTube/YouTube.list,{target_ai}",
        ])
    for item in bundle.get("ai_services") or []:
        conf_lines.append(_as_clash_rule(item, target_ai))
    if use_cn:
        for item in bundle.get("cn_direct") or []:
            conf_lines.append(_as_clash_rule(item, "DIRECT"))
        conf_lines.append("GEOIP,CN,DIRECT,no-resolve")
    else:
        for item in bundle.get("cn_direct") or []:
            kind, target, _payload = _normalize_domain_entry(item)
            if target.lower() in {"lan", "local"}:
                continue
            conf_lines.append(_as_clash_rule(item, "DIRECT"))
    conf_lines.append(f"FINAL,{default_group}")
    return "\n".join(conf_lines) + "\n", "\n".join(uris) + "\n"


def _extract_inline_payload(lines: List[str], key: str) -> List[str]:
    items: List[str] = []
    in_key = False
    in_payload = False
    key_re = re.compile(rf"^  {re.escape(key)}:\s*$")
    for line in lines:
        if key_re.match(line):
            in_key = True
            in_payload = False
            continue
        if in_key and not in_payload:
            if line.strip() == "payload:":
                in_payload = True
                continue
            if re.match(r"^  [A-Za-z0-9_-]+:\s*$", line):
                break
            continue
        if in_payload:
            m = re.match(r"^    - (.+)$", line)
            if m:
                items.append(m.group(1).strip())
                continue
            if not line.strip() or line.strip().startswith("#"):
                continue
            if re.match(r"^  [A-Za-z0-9_-]+:", line) or line.startswith("rules:"):
                break
            break
    return items


def _extract_shadowrocket_rules(text: str, policy: Optional[str] = None) -> List[Tuple[str, str, str]]:
    """Return (kind, target, policy) for DOMAIN* rules in a Shadowrocket conf."""
    out: List[Tuple[str, str, str]] = []
    for raw in text.splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("- "):
            s = s[2:].strip()
        parts = [p.strip() for p in s.split(",")]
        if len(parts) < 3:
            continue
        kind = parts[0].upper()
        if kind not in {"DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD"}:
            continue
        target = parts[1]
        dest = parts[2]
        if policy is not None and dest != policy:
            continue
        out.append((kind, target, dest))
    return out


def migrate_legacy_rules(repo_root: Path, dest_profile: str = "cn-strict") -> int:
    """Merge domain rules from legacy client templates into a rule profile.

    Reads Clash inline payloads ( +.domain and exact names ) and Shadowrocket
    DOMAIN* / DIRECT (and Google-group) lines. Existing profile entries are kept.
    """
    dest_dir = repo_root / "rules" / "profiles" / dest_profile
    dest_dir.mkdir(parents=True, exist_ok=True)
    sources = [
        repo_root / "legacy" / "flclash-strict.template.yaml",
        repo_root / "clients" / "flclash-strict.template.yaml",
        repo_root / "legacy" / "shadowrocket.template.conf",
        repo_root / "clients" / "shadowrocket.template.conf",
    ]
    found = [p for p in sources if p.exists()]
    if not found:
        print("No legacy client template found under legacy/ or clients/; leaving rule lists unchanged.")
        return 0

    google_items: List[str] = []
    cn_items: List[str] = []
    google_seen = set()
    cn_seen = set()

    def add(bucket: List[str], seen: set, item: str) -> None:
        kind, target, payload = _normalize_domain_entry(item)
        key = f"{kind},{target.lower()}"
        if key in seen:
            return
        seen.add(key)
        bucket.append(payload)

    for path in found:
        raw = path.read_text(encoding="utf-8")
        if path.suffix in {".yaml", ".yml"}:
            lines = raw.splitlines()
            for item in _extract_inline_payload(lines, "google-extra"):
                add(google_items, google_seen, item)
            for item in _extract_inline_payload(lines, "cn-allowlist"):
                add(cn_items, cn_seen, item)
            for kind, target, dest in _extract_shadowrocket_rules(raw):
                # YAML rule lines such as DOMAIN-SUFFIX,lan,DIRECT
                if dest == "DIRECT":
                    add(cn_items, cn_seen, f"{kind},{target}")
        else:
            for kind, target, dest in _extract_shadowrocket_rules(raw):
                if dest.upper() in {"GOOGLE", "AI-GOOGLE", "AI / GOOGLE"}:
                    add(google_items, google_seen, f"{kind},{target}")
                elif dest == "DIRECT":
                    add(cn_items, cn_seen, f"{kind},{target}")

    def merge_into(filename: str, incoming: List[str]) -> Tuple[int, int]:
        dest = dest_dir / filename
        existing = _read_rule_list(dest)
        existing_keys = set()
        for item in existing:
            kind, target, _payload = _normalize_domain_entry(item)
            existing_keys.add(f"{kind},{target.lower()}")
        added = 0
        merged = list(existing)
        for item in incoming:
            kind, target, payload = _normalize_domain_entry(item)
            key = f"{kind},{target.lower()}"
            if key in existing_keys:
                continue
            existing_keys.add(key)
            merged.append(payload)
            added += 1
        header = [ln for ln in (dest.read_text(encoding="utf-8").splitlines() if dest.exists() else []) if ln.startswith("#")]
        if not header:
            header = [f"# Migrated and merged domain list ({filename})"]
        dest.write_text("\n".join(header + merged) + "\n", encoding="utf-8")
        return len(existing), added

    g_had, g_added = merge_into("google-extra.list", google_items)
    c_had, c_added = merge_into("cn-direct.list", cn_items)
    print(
        f"Migration sources: {', '.join(str(p.relative_to(repo_root)) if p.is_relative_to(repo_root) else str(p) for p in found)}"
    )
    print(f"google-extra: scanned {len(google_items)}, already in profile {g_had}, added {g_added}")
    print(f"cn-direct: scanned {len(cn_items)}, already in profile {c_had}, added {c_added}")
    print(f"Wrote {dest_dir / 'google-extra.list'} and {dest_dir / 'cn-direct.list'}")
    return 0


def run_interactive_wizard(out_topology: Path) -> int:
    def ask(prompt: str, default: str = "") -> str:
        suffix = f" [{default}]" if default else ""
        ans = input(f"{prompt}{suffix}: ").strip()
        return ans if ans else default

    print("=== proxy-deploy-kit 交互式拓扑向导 ===")
    print("本向导只询问必要信息，不会要求你在终端里粘贴密码、密钥或 UUID。")
    print("凭证请稍后写入本文件（权限 0600）或通过 Agent 所在平台的密钥能力提供。")
    instance = ask("1. 中转实例英文标识（用于 systemd 与目录命名）", "relay-main")
    public_host = ask("2. 中转服务器公网 IP 或域名（可先填占位符）", "<RELAY_PUBLIC_IP_OR_DOMAIN>")
    listen_port = int(ask("3. 代理监听端口", "443"))
    ssh_port = int(ask("4. 服务器 SSH 端口（UFW 防锁死）", "22"))
    enable_vless = ask("5. 启用 VLESS + Reality 入站? (y/n)", "y").lower().startswith("y")
    sni = ask("   Reality 伪装 SNI 域名", "www.cloudflare.com") if enable_vless else "www.cloudflare.com"
    enable_hy2 = ask("6. 启用 Hysteria2 入站? (y/n)", "y").lower().startswith("y")
    rule_profile = ask("7. 客户端分流方案：default（通用，不含中国直连）或 cn-strict（国内白名单直连）", "default")
    exit_count = int(ask("8. 需要配置几个出口?", "1"))

    exits: List[Dict[str, Any]] = []
    for i in range(1, exit_count + 1):
        print(f"\n--- 配置第 {i}/{exit_count} 个出口 ---")
        ex_id = ask("  出口内部英文 ID", f"exit-{i}")
        label = ask("  客户端显示名称", ex_id)
        ex_type = ask("  连接类型 (direct / http / socks / wireguard / vless / shadowsocks)", "direct")
        strict = ask("  启用严格防泄漏预设（纯 IPv4 + 隧道内 DNS + 默认阻断内层 UDP）? (y/n)", "y" if ex_type == "wireguard" else "n").lower().startswith("y")
        ex_obj: Dict[str, Any] = {
            "id": ex_id,
            "label": label,
            "type": ex_type,
            "ip_strategy": "ipv4_only" if strict else "prefer_ipv4",
            "dns_detour": ex_type == "wireguard" or strict,
            "allow_udp": not strict,
            "groups": ["正常代理", "AI-Google"],
        }
        if ex_type in ("http", "socks"):
            proto = ex_type.upper()
            ex_obj["upstream"] = {
                "host": ask(f"  上游主机（可填 <UPSTREAM_{proto}_HOST>）", f"<UPSTREAM_{proto}_HOST>"),
                "port": int(ask("  上游端口", "1080")),
                "username": f"<UPSTREAM_{proto}_USER>",
                "password": f"<UPSTREAM_{proto}_PASS>",
            }
            print(f"  已写入用户名/密码占位符，请稍后在 {out_topology} 里填写，不要在聊天里发送。")
        elif ex_type == "wireguard":
            ex_obj["upstream"] = {
                "local_ipv4": ask("  本机隧道内网 IPv4/CIDR", "10.66.66.2/32"),
                "private_key": "<WG_CLIENT_PRIVATE_KEY>",
                "peer_host": ask("  对端 Endpoint（可填 <WG_ENDPOINT_HOST>）", "<WG_ENDPOINT_HOST>"),
                "peer_port": int(ask("  对端 Endpoint 端口", "51820")),
                "peer_public_key": "<WG_SERVER_PUBLIC_KEY>",
                "mtu": int(ask("  隧道 MTU", "1280")),
            }
            print("  已写入 WireGuard 密钥占位符，请稍后在本地文件中填写。")
        elif ex_type == "vless":
            ex_obj["upstream"] = {
                "host": ask("  下游 VLESS 服务器地址（可填占位符）", "<UPSTREAM_VLESS_HOST>"),
                "port": int(ask("  下游 VLESS 端口", "443")),
                "uuid": "<UPSTREAM_VLESS_UUID>",
                "server_name": ask("  下游 TLS SNI", "www.cloudflare.com"),
            }
            print("  已写入 UUID 占位符，请稍后在本地文件中填写。")
        elif ex_type == "shadowsocks":
            ex_obj["upstream"] = {
                "host": ask("  下游 Shadowsocks 地址（可填占位符）", "<UPSTREAM_SS_HOST>"),
                "port": int(ask("  下游 Shadowsocks 端口", "8388")),
                "method": ask("  加密算法", "2022-blake3-aes-128-gcm"),
                "password": "<UPSTREAM_SS_PASS>",
            }
            print("  已写入密码占位符，请稍后在本地文件中填写。")
        exits.append(ex_obj)

    topo = {
        "instance": instance,
        "relay": {
            "public_host": public_host,
            "listen": "::",
            "listen_port": listen_port,
            "ssh_port": ssh_port,
            "log_level": "warn",
            "vless_reality": {"enabled": enable_vless, "server_name": sni, "private_key": "auto", "public_key": "auto", "short_id": "auto"},
            "hysteria2": {"enabled": enable_hy2, "auto_self_signed": True},
        },
        "exits": exits,
        "clients": {
            "mixed_port": 7890,
            "enable_tun": True,
            "rule_mode": "inline",
            "rule_profile": rule_profile,
            "default_group": "正常代理",
            "ai_group": "AI-Google",
        },
    }
    write_secret_file(out_topology, dump_yaml_or_json(topo), 0o600)
    print(f"\n已写入私有拓扑清单（权限 0600）: {out_topology}")
    print("请在本地填好占位符后再渲染。不要把填好的文件提交到 git。")
    print(f"  python3 scripts/render-topology.py --topology {out_topology} --out-dir build/{instance} --generate-secrets")
    return 0





def run_selftest() -> int:
    with tempfile.TemporaryDirectory(prefix="pdk_selftest_") as td:
        td_path = Path(td)
        sample_yaml = """
instance: edge-hub
relay:
  public_host: "198.51.100.42"
  listen_port: 8443
  ssh_port: 2222
  vless_reality:
    enabled: true
    server_name: www.cloudflare.com
  hysteria2:
    enabled: true
    up_mbps: 150
    down_mbps: 300
    cert_san: www.bing.com
    auto_self_signed: true

exits:
  - id: site-direct
    label: "本机直出"
    type: direct
    allow_udp: true
    groups: ["正常代理"]
  - id: edge-http
    label: "专线转发"
    type: http
    allow_udp: false
    groups: ["正常代理", "AI-Google"]
    upstream:
      host: "203.0.113.88"
      port: 31280
      username: "u1"
      password: "p1"
  - id: home-wg
    label: "家宽隧道"
    type: wireguard
    ip_strategy: ipv4_only
    dns_detour: true
    allow_udp: false
    groups: ["正常代理", "AI-Google"]
    upstream:
      local_ipv4: "10.99.0.2/32"
      private_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
      peer_host: "198.51.100.99"
      peer_port: 51820
      peer_public_key: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
      mtu: 1280
clients:
  rule_profile: default
"""
        parsed_min = _minimal_yaml_load(sample_yaml)
        assert parsed_min["instance"] == "edge-hub"
        assert len(parsed_min["exits"]) == 3

        topo_file = td_path / "topo.yaml"
        topo_file.write_text(sample_yaml, encoding="utf-8")
        out_dir = td_path / "build"
        resolved = validate_and_resolve(load_topology_file(topo_file), out_dir, generate_secrets=True)
        srv = build_singbox_server_config(resolved)

        udp_rules = [r for r in srv["route"]["rules"] if r.get("network") == ["udp"]]
        assert len(udp_rules) == 1
        assert set(udp_rules[0]["auth_user"]) == {"edge-http", "home-wg"}

        assert len(srv["endpoints"]) == 1
        assert srv["endpoints"][0]["tag"] == "exit-home-wg"
        detour_dns = [d for d in srv["dns"]["servers"] if d.get("detour") == "exit-home-wg"]
        assert len(detour_dns) == 2

        chain = [r for r in srv["dns"]["rules"] if r.get("auth_user") == ["home-wg"]]
        actions = [r.get("action") for r in chain]
        assert any(r.get("query_type") == ["AAAA"] and r.get("action") == "reject" for r in chain)
        ev = [r for r in chain if r.get("action") == "evaluate"]
        assert ev[0]["server"] == "dns-home-wg"
        assert any(r.get("server") == "dns-home-wg-backup" for r in ev)
        assert "respond" in actions
        assert chain[-1]["action"] == "reject"
        assert all("strategy" not in r for r in srv["dns"]["rules"])

        leak_topo = copy.deepcopy(parsed_min)
        leak_topo["relay"]["vless_reality"] = {
            "enabled": True,
            "private_key": "x" * 43,
            "public_key": "y" * 43,
            "short_id": "aabbccdd",
            "server_name": "www.cloudflare.com",
        }
        leak_topo["relay"]["hysteria2"] = {"enabled": False}
        leak_topo["exits"] = [{
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
        }]
        try:
            validate_and_resolve(leak_topo, td_path, generate_secrets=False, allow_placeholders=False)
            raise AssertionError("expected placeholder error")
        except ValueError as exc:
            msg = str(exc)
            assert "upstream.host" in msg
            assert "SuperSecretTestOnly_XYZ" not in msg
            assert "filleduser" not in msg

        bundle = load_rule_bundle(resolved, REPO_ROOT)
        clash_txt = build_flclash_yaml(resolved, bundle)
        sr_txt, uri_txt = build_shadowrocket_conf_and_uris(resolved, bundle)
        pin = resolved["relay"]["hysteria2"]["cert_pin_sha256"]
        assert pin in clash_txt
        assert "listen: 127.0.0.1:1053" in clash_txt
        assert "respect-rules: true" in clash_txt
        assert "listen: 0.0.0.0:1053" not in clash_txt
        assert "IP-CIDR,198.51.100.42/32,DIRECT,no-resolve" in clash_txt
        assert "IP-CIDR,198.51.100.42/32,DIRECT,no-resolve" in sr_txt
        assert "GEOIP,CN" not in clash_txt
        assert "GEOIP,CN" not in sr_txt
        assert "vless://" in uri_txt and "hysteria2://" in uri_txt
    print("[render-topology] selftest PASSED")
    return 0


def _bundle_for_args(resolved: Dict[str, Any], rules_dir: Path) -> Dict[str, Any]:
    default_root = (REPO_ROOT / "rules").resolve()
    chosen = Path(rules_dir).resolve()
    if chosen == default_root:
        return load_rule_bundle(resolved, REPO_ROOT)
    return load_rule_bundle(resolved, REPO_ROOT, rules_dir=chosen)


def main() -> int:
    parser = argparse.ArgumentParser(description="Compile a topology file into server and client configs")
    parser.add_argument("--topology", type=Path, help="Input topology .yaml or .json file")
    parser.add_argument("--out-dir", type=Path, help="Output directory (default: build/<instance>)")
    parser.add_argument("--generate-secrets", action="store_true", help="Generate UUIDs, Reality keys, HY2 passwords and a self-signed cert when set to auto")
    parser.add_argument("--allow-placeholders", action="store_true", help="Allow unfilled <PLACEHOLDER> values (for dry inspection only)")
    parser.add_argument("--rules-dir", type=Path, default=REPO_ROOT / "rules", help="Override rule profile directory (default: rules/profiles/<rule_profile>)")
    parser.add_argument("--interactive", action="store_true", help="Run the terminal interview to create a topology file")
    parser.add_argument("--out-topology", type=Path, default=Path("topology.local.yaml"), help="Destination for --interactive")
    parser.add_argument("--migrate-legacy-rules", action="store_true", help="Merge domain rules from legacy/ client templates into rules/profiles/cn-strict/")
    parser.add_argument("--selftest", action="store_true", help="Run the built-in smoke test")
    args = parser.parse_args()

    if args.selftest:
        return run_selftest()
    if args.migrate_legacy_rules:
        return migrate_legacy_rules(REPO_ROOT)
    if args.interactive:
        return run_interactive_wizard(args.out_topology)
    if not args.topology:
        parser.error("--topology PATH is required (or pass --interactive / --selftest)")

    raw_topo = load_topology_file(args.topology)
    inst_preview = str(raw_topo.get("instance", "relay")).strip() or "relay"
    out_dir = args.out_dir or (REPO_ROOT / "build" / inst_preview)

    resolved = validate_and_resolve(
        raw_topo,
        out_dir,
        generate_secrets=args.generate_secrets,
        allow_placeholders=args.allow_placeholders,
    )
    instance = resolved["instance"]

    srv_cfg = build_singbox_server_config(resolved)
    unit_txt = render_systemd_unit(instance)
    bundle = _bundle_for_args(resolved, args.rules_dir)
    clash_txt = build_flclash_yaml(resolved, bundle)
    sr_txt, uri_txt = build_shadowrocket_conf_and_uris(resolved, bundle)

    srv_path = out_dir / "server" / "config.json"
    unit_path = out_dir / "server" / f"sing-box-{instance}.service"
    clash_path = out_dir / "clients" / "flclash.yaml"
    sr_path = out_dir / "clients" / "shadowrocket.conf"
    uri_path = out_dir / "clients" / "nodes-uri.txt"
    resolved_path = out_dir / "topology.resolved.yaml"

    write_secret_file(srv_path, json.dumps(srv_cfg, indent=2, ensure_ascii=False) + "\n", 0o600)
    write_secret_file(unit_path, unit_txt, 0o644)
    write_secret_file(clash_path, clash_txt, 0o600)
    write_secret_file(sr_path, sr_txt, 0o600)
    write_secret_file(uri_path, uri_txt, 0o600)
    write_secret_file(resolved_path, dump_yaml_or_json(resolved), 0o600)

    print(f"[render-topology] instance={instance} exits={len(resolved['exits'])} rule_profile={bundle.get('profile')}")
    print(f"  server config : {srv_path} (0600)")
    print(f"  systemd unit  : {unit_path}")
    print(f"  FlClash YAML  : {clash_path} (0600)")
    print(f"  Shadowrocket  : {sr_path} (0600)")
    print(f"  Share URIs    : {uri_path} (0600)")
    print(f"  Resolved lock : {resolved_path} (0600)")
    return 0



if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
