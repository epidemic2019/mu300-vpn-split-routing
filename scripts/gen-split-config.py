#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen-split-config.py — generate a mu300-vpn profile that routes

    * mainland-China destination IPs   -> DIRECT  (bypass the tunnel)
    * everything else                  -> VPN     (route.final = proxy)

for ZTE F50 / MU300 (Unisoc T760) running mu300-linux's OpenWrt + mu300-vpn.

WHY THIS EXISTS
---------------
mu300-vpn is designed as a *whole-device full tunnel + kill switch*. It has no
policy-routing split of its own. Split routing is possible only because the
sing-box driver accepts a RAW configuration profile, whose `route.rules` are
preserved verbatim. So the whole job is: build a valid raw sing-box config whose
rules send CN addresses to a second outbound.

There is a catch, and it is the reason this script has two modes:

    `mu300-vpn gen` derives the proxy parameters from your share link. If you
    hand-write the outbound yourself you may get Reality public key, `flow`,
    `packet_encoding`, TLS SNI or DNS strategy subtly wrong, and the tunnel
    will fail in ways that are painful to debug.

    => Mode B (`--base`) reuses the config the device produced itself.
       That is the recommended path and the one used in production.

MODES
-----
B) --base FILE              [RECOMMENDED]
   `mu300-vpn gen` a throwaway copy of your profile into a sandbox, take its
   `config.json`, keep `outbounds` and `dns` byte-for-byte, and append
   CN-direct rules to `route.rules`. Everything the device expects is preserved
   exactly; only the routing table is extended.

A) --uri URI / --uri-file FILE
   Build the whole config offline from a vless:// vmess:// trojan:// ss:// link.
   Convenient and self-contained, but the parameter mapping is a best-effort
   re-implementation. Prefer mode B when you have a device to ask.

OUTPUTS
-------
  out/<name>.singbox.json   raw sing-box config — the engine the device really
                            uses when KILL_SWITCH=1 (the default)
  out/<name>.xray.json      raw Xray config — only loaded when KILL_SWITCH=0

EXAMPLES
--------
  # Recommended: ask the device for the base config first
  MU300_VPN_RUN=/tmp/gen mu300-vpn gen          # on the device
  scp root@<device>:/tmp/gen/config.json ./device-base.json
  ./gen-split-config.py --base ./device-base.json --lan-cidrs 192.168.1.0/24

  # Fully offline, from a share link
  ./gen-split-config.py --uri-file ./node.uri --ipv6
"""

from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import os
import re
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DATA = os.path.join(ROOT, "data")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Private / reserved ranges -> always DIRECT.
#
# They are not part of the "mainland China" list, so without this rule the
# catch-all would push LAN traffic, loopback and link-local into the tunnel and
# break local networking.
PRIVATE_V4 = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24",
    "192.168.0.0/16","224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32",
]
PRIVATE_V6 = ["::1/128", "::/128", "fc00::/7", "fe80::/10", "ff00::/8", "2001:db8::/32"]

# Placeholder used while building, then substituted with a pretty-printed CIDR
# block. It MUST occupy the *entire* value. Writing ["__SENTINEL__"] and then
# text-replacing the quoted token yields a nested array [[...]], which Xray
# rejects outright with "unknown format of a string list".
CIDR_SENTINEL = "__MU300_CN_CIDRS__"

# 1 MiB is the hard limit the device enforces on a profile file.
MAX_PROFILE_BYTES = 1024 * 1024

# Keys the device strips or refuses. Keeping them out makes the audit simple and
# prevents a stray `listen` from being interpreted somewhere.
FORBIDDEN_ANYWHERE = {
    "listen", "listen_port", "external_controller", "executable_path",
    "data_directory", "torrc", "extra_args", "redirect", "override_address",
    "override_port", "masterkeylog", "private_key_path", "client_key_path",
    "keyfile", "certificatefile", "dssettings",
}

# Top-level keys the raw-config path preserves.
SINGBOX_ALLOW_TOP = {"dns", "outbounds", "route", "endpoints"}
SINGBOX_ALLOW_ROUTE = {"rules", "rule_set", "final", "default_domain_resolver"}
# Overwritten by the device during rebuild; harmless if present.
SINGBOX_ROUTE_TOLERATED = {"auto_detect_interface", "default_mark", "default_interface"}

XRAY_ALLOW_TOP = {"outbounds", "routing", "dns", "fakedns", "observatory", "burstObservatory"}


# ---------------------------------------------------------------------------
# CIDR data
# ---------------------------------------------------------------------------

def load_cidrs(path: str, version: int | None = None) -> list[ipaddress._BaseNetwork]:
    nets = []
    if not os.path.exists(path):
        return nets
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.split("#")[0].strip()
            if not line:
                continue
            try:
                net = ipaddress.ip_network(line, strict=False)
            except ValueError:
                continue
            if version is not None and net.version != version:
                continue
            nets.append(net)
    return nets


def read_uri_file(path: str) -> str:
    """Pick the first usable share link out of a file.

    Blank lines and `#` comments are skipped, so a node file can be annotated.
    The first supported link wins; any further ones are reported so that a
    multi-node file does not silently select the wrong line.
    """
    links = []
    for lineno, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.split("#")[0].strip()
        if not line:
            continue
        if re.match(r"^(vless|vmess|trojan|ss)://", line):
            links.append((lineno, line))
    if not links:
        raise SystemExit("no vless/vmess/trojan/ss link found in %s" % path)
    if len(links) > 1:
        print("note: %s holds %d links; using the first (line %d). "
              "Comment the others out, or pass --uri directly."
              % (path, len(links), links[0][0]))
    return links[0][1]


def collapse(nets) -> list[str]:
    """Deduplicate + merge + sort, so output does not depend on input order."""
    return [str(n) for n in sorted(ipaddress.collapse_addresses(nets),
                                   key=lambda n: (int(n.network_address), n.prefixlen))]


# ---------------------------------------------------------------------------
# Share link -> outbound
# ---------------------------------------------------------------------------

def _b64pad(s: str) -> str:
    return s + "=" * (-len(s) % 4)


def xray_outbound_from_uri(uri: str) -> dict:
    """share link -> Xray proxy outbound."""
    uri = uri.strip()
    m = re.match(r"^(vless|vmess|trojan|ss)://", uri)
    if not m:
        raise SystemExit("unrecognised share link scheme: %s" % uri[:24])
    proto = m.group(1)

    if proto == "vmess":
        body = _b64pad(uri[len("vmess://"):].replace("-", "+").replace("_", "/"))
        j = json.loads(base64.b64decode(body).decode("utf-8"))
        net = j.get("net") or "tcp"
        out = {
            "tag": "proxy", "protocol": "vmess",
            "settings": {"vnext": [{
                "address": j["add"], "port": int(j["port"]),
                "users": [{"id": j["id"], "alterId": int(j.get("aid") or 0),
                           "security": j.get("scy") or "auto"}],
            }]},
            "streamSettings": {"network": "raw" if net in ("tcp", "raw") else net},
        }
        security = (j.get("tls") or "").lower()
        if security in ("tls", "reality"):
            out["streamSettings"]["security"] = security
            if security == "tls":
                out["streamSettings"]["tlsSettings"] = {
                    "serverName": j.get("sni") or j.get("host") or j["add"],
                    "fingerprint": "chrome",
                }
        if net == "ws":
            out["streamSettings"]["wsSettings"] = {"path": j.get("path") or "/"}
            if j.get("host"):
                out["streamSettings"]["wsSettings"]["host"] = j["host"]
        elif net == "grpc":
            out["streamSettings"]["grpcSettings"] = {"serviceName": j.get("path") or ""}
        return out

    parsed = urllib.parse.urlsplit(uri)
    q = dict(urllib.parse.parse_qsl(parsed.query))
    host, port = parsed.hostname, parsed.port
    userinfo = parsed.username or ""

    if proto == "ss":
        try:
            method, _, password = base64.b64decode(_b64pad(userinfo)).decode("utf-8").partition(":")
        except Exception:
            method, password = "none", ""
        return {
            "tag": "proxy", "protocol": "shadowsocks",
            "settings": {"servers": [{"address": host, "port": port,
                                      "method": method, "password": password}]},
            "streamSettings": {"network": "raw"},
        }

    typ = q.get("type") or q.get("headerType") or "tcp"
    if typ in ("tcp", "none", ""):
        typ = "raw"
    net = typ if typ in ("raw", "ws", "grpc", "httpupgrade", "xhttp", "kcp") else "raw"

    if proto == "vless":
        user = {"id": userinfo, "encryption": q.get("encryption") or "none"}
        if q.get("flow"):
            user["flow"] = q["flow"]
        settings = {"vnext": [{"address": host, "port": port, "users": [user]}]}
    else:  # trojan
        settings = {"servers": [{"address": host, "port": port, "password": userinfo}]}

    stream = {"network": net}
    security = (q.get("security") or "none").lower()
    if security == "tls":
        tls = {"serverName": q.get("sni") or q.get("host") or host,
               "fingerprint": q.get("fp") or "chrome"}
        if q.get("alpn"):
            tls["alpn"] = q["alpn"].split(",")
        stream["security"] = "tls"
        stream["tlsSettings"] = tls
    elif security == "reality":
        reality = {"serverName": q.get("sni") or host,
                   "fingerprint": q.get("fp") or "chrome",
                   "publicKey": q.get("pbk") or "",
                   "shortId": q.get("sid") or ""}
        if q.get("spx"):
            reality["spiderX"] = q["spx"]
        stream["security"] = "reality"
        stream["realitySettings"] = reality

    if net == "ws":
        ws = {"path": urllib.parse.unquote(q.get("path") or "/")}
        if q.get("host"):
            ws["host"] = q["host"]
        stream["wsSettings"] = ws
    elif net == "grpc":
        stream["grpcSettings"] = {"serviceName": q.get("serviceName") or ""}
    elif net == "httpupgrade":
        hu = {"path": urllib.parse.unquote(q.get("path") or "/")}
        if q.get("host"):
            hu["host"] = q["host"]
        stream["httpupgradeSettings"] = hu

    return {"tag": "proxy", "protocol": proto, "settings": settings, "streamSettings": stream}


def singbox_outbound_from_uri(uri: str) -> dict:
    """share link -> sing-box 1.12+ proxy outbound."""
    uri = uri.strip()
    m = re.match(r"^(vless|vmess|trojan|ss)://", uri)
    if not m:
        raise SystemExit("unrecognised share link scheme: %s" % uri[:24])
    proto = m.group(1)
    parsed = urllib.parse.urlsplit(uri)
    q = dict(urllib.parse.parse_qsl(parsed.query))
    host, port = parsed.hostname, parsed.port

    if proto == "vless":
        out = {"type": "vless", "tag": "proxy", "server": host, "server_port": port,
               "uuid": parsed.username, "domain_resolver": "bootstrap"}
        if q.get("flow"):
            out["flow"] = q["flow"]
        security = (q.get("security") or "").lower()
        if security in ("tls", "reality"):
            tls = {"enabled": True, "server_name": q.get("sni") or host}
            if q.get("fp"):
                tls["utls"] = {"enabled": True, "fingerprint": q["fp"]}
            if security == "reality":
                tls["reality"] = {"enabled": True, "public_key": q.get("pbk") or "",
                                  "short_id": q.get("sid") or ""}
            out["tls"] = tls
        return out

    if proto == "trojan":
        out = {"type": "trojan", "tag": "proxy", "server": host, "server_port": port,
               "password": parsed.username, "domain_resolver": "bootstrap"}
        if (q.get("security") or "").lower() in ("tls", "reality"):
            out["tls"] = {"enabled": True, "server_name": q.get("sni") or host}
        return out

    if proto == "ss":
        try:
            method, _, password = base64.b64decode(_b64pad(parsed.username or "")).decode("utf-8").partition(":")
        except Exception:
            method, password = "", parsed.username or ""
        return {"type": "shadowsocks", "tag": "proxy", "server": host, "server_port": port,
                "method": method, "password": password, "domain_resolver": "bootstrap"}

    # vmess: parse the base64 body for credentials, keep the query for transport
    body = _b64pad(uri[len("vmess://"):].split("#")[0].replace("-", "+").replace("_", "/"))
    j = json.loads(base64.b64decode(body).decode("utf-8"))
    out = {"type": "vmess", "tag": "proxy", "server": j["add"], "server_port": int(j["port"]),
           "uuid": j["id"], "security": j.get("scy") or "auto",
           "alter_id": int(j.get("aid") or 0), "domain_resolver": "bootstrap"}
    net = j.get("net") or "tcp"
    if net == "ws":
        out["transport"] = {"type": "ws", "path": j.get("path") or "/"}
        if j.get("host"):
            out["transport"]["headers"] = {"Host": j["host"]}
    if (j.get("tls") or "").lower() in ("tls", "reality"):
        out["tls"] = {"enabled": True, "server_name": j.get("sni") or j.get("host") or j["add"]}
    return out


# ---------------------------------------------------------------------------
# Rule assembly
# ---------------------------------------------------------------------------

def singbox_rules(lan_cidrs: list[str], cn_cidrs: list[str]) -> list[dict]:
    """Build route.rules.

    The device's raw-config rebuild only replaces `inbounds`, forces
    `route.default_mark`, and adds its own bootstrap DNS entry. It does NOT
    inject the template rules that `gen` writes for share-link profiles, so the
    full rule list has to be written here.
    """
    rules: list[dict] = [
        # Must come first: without sniffing the engine never sees the protocol.
        {"action": "sniff"},
        # Client DNS is hijacked into the in-tunnel resolver: no DNS leak.
        {"protocol": "dns", "action": "hijack-dns"},
    ]
    if lan_cidrs:
        # LAN sources aimed at *private* destinations must not reach the tunnel.
        # (LAN-to-LAN traffic never gets here: TUN excludes LAN via
        # route_exclude_address.) `reject` matches the upstream template.
        rules.append({"source_ip_cidr": lan_cidrs, "ip_is_private": True, "action": "reject"})
    rules.append({"ip_is_private": True, "outbound": "direct"})
    rules.append({"ip_cidr": CIDR_SENTINEL, "outbound": "direct"})
    return rules


def xray_rules(cn_sentinel, private_v4, private_v6) -> list[dict]:
    return [
        # 1) private / loopback / link-local -> direct (must precede CN)
        {"type": "field", "ip": private_v4 + private_v6, "outboundTag": "direct"},
        # 2) mainland China -> direct
        {"type": "field", "ip": cn_sentinel, "outboundTag": "direct"},
        # 3) catch-all -> tunnel
        {"type": "field", "network": "tcp,udp", "outboundTag": "proxy"},
    ]


def direct_singbox() -> dict:
    return {"type": "direct", "tag": "direct"}


def direct_xray() -> dict:
    """The Xray DIRECT outbound.

    `streamSettings` must exist even if empty: the device only writes
    `sockopt.mark` into outbounds that already have a streamSettings object, and
    an unmarked packet is dropped by the kill switch. "Direct" without the mark
    is not direct — it is a black hole.
    """
    return {"tag": "direct", "protocol": "freedom",
            "settings": {"domainStrategy": "UseIP"}, "streamSettings": {}}


# ---------------------------------------------------------------------------
# Rendering with self-checks
# ---------------------------------------------------------------------------

def _walk(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield k, v, path + "." + k
            yield from _walk(v, path + "." + k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield None, v, "%s[%d]" % (path, i)
            yield from _walk(v, "%s[%d]" % (path, i))


def render(obj: dict, cidrs: list[str], per_line: int = 8) -> str:
    """JSON-encode, then expand the sentinel into a readable CIDR block."""
    text = json.dumps(obj, indent=2, ensure_ascii=False)
    token = '"%s"' % CIDR_SENTINEL
    if token not in text:
        raise SystemExit("internal error: CIDR sentinel missing from output")
    block = "[\n" + ",\n".join(
        ", ".join('"%s"' % c for c in cidrs[i:i + per_line])
        for i in range(0, len(cidrs), per_line)
    ) + "\n]"
    text = text.replace(token, block)
    if CIDR_SENTINEL in text:
        raise SystemExit("internal error: CIDR sentinel was not substituted")

    doc = json.loads(text)  # must still parse
    for _, value, path in _walk(doc):
        if isinstance(value, list) and path.endswith("]"):
            # a list inside a list means the sentinel was written as an element
            parent = path.rsplit("[", 1)[0]
            for _, pv, ppath in _walk(doc):
                if ppath == parent and isinstance(pv, list):
                    raise SystemExit(
                        "nested array detected at %s — the sentinel must be the entire "
                        "value, not an element of a list" % path)
    return text + "\n"


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------

def lan_from_base(base: dict) -> list[str]:
    """Recover the LAN subnet from a device-generated config.

    `gen` bakes the configured LAN_CIDRS into the TUN's route_exclude_address, so
    a base config already knows the answer — better than making the caller guess
    and then silently generating a config with the wrong subnet.
    """
    for inbound in base.get("inbounds", []) or []:
        if not isinstance(inbound, dict):
            continue
        excl = inbound.get("route_exclude_address") or inbound.get("route_exclude_address_set")
        if isinstance(excl, list) and excl:
            return [e for e in excl if isinstance(e, str)]
    return []


def is_template_rule(r: dict) -> bool:
    """Recognise a rule that this script is about to (re)generate.

    `mu300-vpn gen` writes its own template rules for share-link profiles
    (sniff / hijack-dns / LAN reject / private direct). When a device-generated
    config is used as `--base`, those are already present, so they have to be
    stripped before ours are added — otherwise every proxy request is evaluated
    twice against duplicate rules, and the file grows for no reason.

    Rules the user added by hand do not match any of these shapes and survive.
    """
    if set(r) == {"action"} and r.get("action") == "sniff":
        return True
    if r.get("action") == "hijack-dns" and "protocol" in r:
        return True
    if r.get("action") == "reject" and "source_ip_cidr" in r and r.get("ip_is_private") is True:
        return True
    if r.get("outbound") == "direct" and r.get("ip_is_private") is True:
        return True
    if r.get("outbound") == "direct" and isinstance(r.get("ip_cidr"), list) \
            and len(r["ip_cidr"]) > 100:
        return True
    return False


def build_singbox_from_base(base: dict, cn_v4: list[str], cn_v6: list[str],
                           lan_cidrs: list[str]) -> tuple[dict, list[str]]:
    notes = []
    cfg = json.loads(json.dumps(base))  # deep copy

    dropped = [k for k in cfg if k not in SINGBOX_ALLOW_TOP]
    for k in dropped:
        cfg.pop(k)
    if dropped:
        notes.append("dropped top-level keys: %s" % ", ".join(dropped))
    if "outbounds" not in cfg:
        raise SystemExit("base config has no `outbounds` — is this really a mu300-vpn gen output?")

    route = cfg.setdefault("route", {})
    rdrop = [k for k in route if k not in SINGBOX_ALLOW_ROUTE | SINGBOX_ROUTE_TOLERATED]
    for k in rdrop:
        route.pop(k, None)
    if rdrop:
        notes.append("dropped route keys: %s" % ", ".join(rdrop))

    rules = route.setdefault("rules", [])
    kept = [r for r in rules if not (isinstance(r, dict) and is_template_rule(r))]
    n_dropped = len(rules) - len(kept)
    if n_dropped:
        notes.append("replaced %d existing template rule(s)" % n_dropped)
    # ours go first; anything custom that was already there keeps its relative order
    route["rules"] = singbox_rules(lan_cidrs, cn_v4 + cn_v6) + kept
    route.setdefault("final", "proxy")
    return cfg, notes


def build_singbox_from_uri(proxy_out: dict, cn_v4: list[str], cn_v6: list[str],
                           lan_cidrs: list[str]) -> dict:
    return {
        "dns": {
            "servers": [
                {"type": "udp", "tag": "remote", "server": "1.1.1.1", "detour": "proxy"},
                {"type": "udp", "tag": "bootstrap", "server": "1.1.1.1"},
            ],
            "final": "remote",
            "strategy": "ipv4_only",
        },
        "outbounds": [proxy_out, direct_singbox()],
        "route": {"rules": singbox_rules(lan_cidrs, cn_v4 + cn_v6), "final": "proxy"},
    }


def build_xray(outs: list[dict], cn_v4: list[str], cn_v6: list[str], ipv6: bool) -> dict:
    private_v6 = PRIVATE_V6 if ipv6 else []
    return {
        "outbounds": outs,
        "routing": {"rules": xray_rules(CIDR_SENTINEL, PRIVATE_V4, private_v6)},
    }


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate(cfg: dict, kind: str) -> list[str]:
    errs: list[str] = []

    keys = [k for k, _, _ in _walk(cfg)]
    hit = sorted({k for k in keys if k and k.lower() in FORBIDDEN_ANYWHERE})
    if hit:
        errs.append("contains refused key(s): %s" % ", ".join(hit))

    tags = [o.get("tag") for o in cfg.get("outbounds", []) if isinstance(o, dict)]
    if len(set(tags)) != len(tags):
        errs.append("duplicate outbound tags: %s" % tags)

    if kind == "singbox":
        route = cfg.get("route", {})
        for i, r in enumerate(route.get("rules", [])):
            ob = r.get("outbound")
            if ob and ob not in tags:
                errs.append("route.rules[%d].outbound=%s is not a known outbound %s" % (i, ob, tags))
            if r.get("action") not in (None, "sniff", "hijack-dns", "reject", "route"):
                errs.append("route.rules[%d].action=%s is not recognised" % (i, r.get("action")))
        if route.get("final") not in tags:
            errs.append("route.final=%s is not a known outbound %s" % (route.get("final"), tags))
        dns_tags = {s.get("tag") for s in cfg.get("dns", {}).get("servers", []) if isinstance(s, dict)}
        for s in cfg.get("dns", {}).get("servers", []):
            if not isinstance(s, dict):
                continue
            if s.get("detour") and s["detour"] not in tags:
                errs.append("dns server %s detour=%s is not an outbound" % (s.get("tag"), s["detour"]))
            dr = s.get("domain_resolver")
            if isinstance(dr, str) and dr not in dns_tags:
                errs.append("dns server %s domain_resolver=%s is not a dns server" % (s.get("tag"), dr))
        for o in cfg.get("outbounds", []):
            dr = o.get("domain_resolver")
            if isinstance(dr, str) and dr not in dns_tags:
                errs.append("outbound %s domain_resolver=%s is not a dns server" % (o.get("tag"), dr))
    else:
        routing_tags = {r.get("outboundTag") for r in cfg.get("routing", {}).get("rules", [])}
        for t in routing_tags:
            if t and t not in tags:
                errs.append("routing rule outboundTag=%s is not a known outbound %s" % (t, tags))

    for i, r in enumerate(cfg.get("routing", {}).get("rules", []) if kind == "xray"
                          else cfg.get("route", {}).get("rules", [])):
        field = "ip" if kind == "xray" else "ip_cidr"
        if isinstance(r.get(field), list) and any(isinstance(x, list) for x in r[field]):
            errs.append("rule[%d].%s contains a nested array" % (i, field))

    return errs


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description="Generate a mu300-vpn split-routing profile (CN direct, rest via VPN).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("EXAMPLES")[-1] if "EXAMPLES" in __doc__ else None)
    src = ap.add_argument_group("node source (at least one is required)")
    src.add_argument("--base", metavar="FILE",
                     help="config.json produced by `mu300-vpn gen` (RECOMMENDED)")
    src.add_argument("--uri", metavar="URI", help="share link, inline")
    src.add_argument("--uri-file", metavar="FILE", help="share link, from a file")
    src.add_argument("--from-xray", metavar="FILE",
                     help="reuse the `outbounds` of an Xray config generated by the device")

    data = ap.add_argument_group("data")
    data.add_argument("--cn-ipv4", default=os.path.join(DATA, "cn-ipv4.txt"))
    data.add_argument("--cn-ipv6", default=os.path.join(DATA, "cn-ipv6.txt"))
    data.add_argument("--ipv6", action="store_true",
                      help="also route mainland-China IPv6 to direct (needed only when "
                           "the device has `mu300-vpn settings IPV6=1`)")

    net = ap.add_argument_group("network")
    net.add_argument("--lan-cidrs", default=None,
                     help="the device's LAN subnet; must match `mu300-vpn settings LAN_CIDRS`. "
                          "Omit it in --base mode and it is read back out of the base config. "
                          "F50 factory default: 192.168.77.0/24")

    out = ap.add_argument_group("output")
    out.add_argument("--name", default="split-cn", help="profile/output base name")
    out.add_argument("--outdir", default=os.path.join(ROOT, "out"))
    out.add_argument("--no-xray", action="store_true",
                     help="skip the Xray output even in link mode")
    a = ap.parse_args()

    uri = a.uri or (read_uri_file(a.uri_file) if a.uri_file else "")
    if not (a.base or uri or a.from_xray):
        ap.error("need at least one of --base / --uri / --uri-file / --from-xray")

    cn4 = collapse(load_cidrs(a.cn_ipv4, 4))
    cn6 = collapse(load_cidrs(a.cn_ipv6, 6)) if a.ipv6 else []
    if not cn4:
        ap.error("no IPv4 ranges read from %s (run scripts/fetch-cn-cidrs.sh)" % a.cn_ipv4)

    # ---- LAN subnet: explicit flag > read back from the base config > stock default
    lan_note = ""
    if a.lan_cidrs is not None:
        lan = [c.strip() for c in a.lan_cidrs.split(",") if c.strip()]
        lan_note = "(--lan-cidrs)"
    else:
        lan = []
        if a.base:
            lan = lan_from_base(json.load(open(a.base, encoding="utf-8")))
            if lan:
                lan_note = "(read back from the base config's route_exclude_address)"
        if not lan:
            lan = ["192.168.77.0/24"]
            lan_note = "(F50 stock default — VERIFY against " \
                       "`mu300-vpn settings get LAN_CIDRS`)"

    os.makedirs(a.outdir, exist_ok=True)
    written: list[tuple[str, int]] = []
    problems: list[str] = []

    print("mainland-China IPv4 : %d ranges after collapsing" % len(cn4))
    print("mainland-China IPv6 : %s" % ("%d ranges" % len(cn6) if cn6 else "not included (--ipv6 to add)"))
    print("LAN subnet          : %s  %s" % (", ".join(lan) or "(none)", lan_note))
    print()

    # ---- sing-box ----
    sb_cfg = None
    if a.base:
        base = json.load(open(a.base, encoding="utf-8"))
        sb_cfg, notes = build_singbox_from_base(base, cn4, cn6, lan)
        print("[sing-box] source : %s" % a.base)
        for n in notes:
            print("           %s" % n)
    elif uri:
        sb_cfg = build_singbox_from_uri(singbox_outbound_from_uri(uri), cn4, cn6, lan)
        print("[sing-box] source : share link (offline mapping)")
    else:
        print("[sing-box] source : --from-xray given but no share link; "
              "using it for the Xray output only")

    if sb_cfg is not None:
        problems += ["sing-box: " + e for e in validate(sb_cfg, "singbox")]
        text = render(sb_cfg, cn4 + cn6)
        path = os.path.join(a.outdir, "%s.singbox.json" % a.name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        written.append((path, len(text.encode())))
        print("[sing-box] rules  :")
        for i, r in enumerate(sb_cfg["route"]["rules"]):
            show = dict(r)
            if show.get("ip_cidr") == CIDR_SENTINEL:
                show["ip_cidr"] = "<%d ranges>" % len(cn4 + cn6)
            elif isinstance(show.get("ip_cidr"), list):
                show["ip_cidr"] = "<%d ranges>" % len(show["ip_cidr"])
            if isinstance(show.get("source_ip_cidr"), list):
                show["source_ip_cidr"] = "<%s>" % ",".join(show["source_ip_cidr"])
            print("           [%d] %s" % (i, json.dumps(show, ensure_ascii=False)))
        print("[sing-box] final  : %s" % sb_cfg["route"]["final"])

    # ---- Xray ----
    if uri and not a.no_xray:
        outs = [xray_outbound_from_uri(uri), direct_xray()]
        x_cfg = build_xray(outs, cn4, cn6, a.ipv6)
        problems += ["xray: " + e for e in validate(x_cfg, "xray")]
        text = render(x_cfg, cn4 + cn6)
        path = os.path.join(a.outdir, "%s.xray.json" % a.name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        written.append((path, len(text.encode())))
        print("[xray    ] source : share link (offline mapping; loaded only when KILL_SWITCH=0)")

    print()
    for path, size in written:
        flag = "OK" if size <= MAX_PROFILE_BYTES else "** OVER 1 MiB LIMIT **"
        print("%-46s %9d bytes  %s" % (os.path.basename(path), size, flag))
        if size > MAX_PROFILE_BYTES:
            problems.append("%s exceeds the 1 MiB profile limit" % os.path.basename(path))

    if problems:
        print()
        print("SELF-CHECK FAILED:", file=sys.stderr)
        for p in problems:
            print("  - %s" % p, file=sys.stderr)
        return 1

    print()
    print("self-check : passed (no nested arrays, no refused keys, "
          "every outbound / detour resolves, within size limit)")
    if written:
        print()
        print("next       : scripts/deploy.sh --host <device-ip> --config %s" % written[0][0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
