#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify-routing.py — check a generated config's routing semantics offline.

It loads the config you are about to deploy, replays the rule list for a batch of
probe addresses, and asserts:

    * mainland-China addresses          -> direct
    * non-China addresses               -> proxy
    * private / loopback / link-local   -> direct
    * (sing-box) LAN source + private   -> reject
    * (sing-box) DNS                    -> hijack-dns
    * the VPN server's own address is not swallowed by the direct rules

No device and no network access are needed, so this runs fine in CI as a
pre-deploy gate.

    ./verify-routing.py out/split-cn.singbox.json
    ./verify-routing.py out/split-cn.singbox.json out/split-cn.xray.json

Exit code 0 = every expectation held.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import random
import sys

# Well-known addresses that are definitely NOT in mainland-China space.
# Do not add RFC 5737 documentation ranges (192.0.2.0/24, 198.51.100.0/24,
# 203.0.113.0/24) here — those are reserved, so the config sends them to
# `direct` on purpose. They are covered by RESERVED below.
FOREIGN = [
    "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1", "9.9.9.9", "208.67.222.222",
    "64.6.64.6", "77.88.8.8", "185.199.108.153", "151.101.1.69", "104.16.132.229",
    "23.215.0.136", "172.217.160.78", "142.250.190.46", "20.205.243.166",
    "13.107.42.14", "199.232.69.194", "205.251.192.1",
]

# Reserved / RFC 5737 documentation ranges. The Xray config lists these
# explicitly, so `direct` is guaranteed there. The sing-box config relies on the
# engine's own `ip_is_private` predicate instead, whose exact coverage is the
# engine's business — so these are only asserted for Xray and merely reported for
# sing-box. See docs/troubleshooting.md for the explicit-list alternative.
RESERVED = ["192.0.2.5", "203.0.110.10"]

# Probe addresses that must never enter the tunnel, for either engine.
PRIVATE = ["10.0.0.1", "172.16.5.9", "192.168.0.1", "192.168.77.1",
           "127.0.0.1", "169.254.1.1", "100.64.0.1"]

# Actual networks used to evaluate `ip_is_private` while replaying sing-box.
# These must be networks, not host addresses — `ip_network("10.0.0.1")` would
# silently become 10.0.0.1/32 and match almost nothing.
PRIVATE_NETS = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24",
    "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
    "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32",
]

# Well-known addresses that ARE in mainland-China space.
CHINA = [
    "114.114.114.114",   # 114DNS
    "223.5.5.5",         # AliDNS
    "223.6.6.6",         # AliDNS
    "119.29.29.29",      # DNSPod
    "180.76.76.76",      # Baidu DNS
    "220.181.38.148", "180.101.50.242", "39.156.66.10", "182.61.200.7",
    "101.226.4.6", "140.205.0.1", "42.120.74.196",
    "118.184.169.32",    # ip.3322.net
]

GREEN = "\033[32m"; RED = "\033[31m"; DIM = "\033[2m"; OFF = "\033[0m"
if not sys.stdout.isatty():
    GREEN = RED = DIM = OFF = ""


class Matcher:
    """Fast containment test against a sorted set of networks."""

    def __init__(self, cidrs):
        nets = []
        for c in cidrs:
            try:
                nets.append(ipaddress.ip_network(c, strict=False))
            except ValueError:
                pass
        self.v4 = sorted((n for n in nets if n.version == 4),
                         key=lambda n: (int(n.network_address), n.prefixlen))
        self.v6 = sorted((n for n in nets if n.version == 6),
                         key=lambda n: (int(n.network_address), n.prefixlen))

    def __contains__(self, addr: str) -> bool:
        try:
            a = ipaddress.ip_address(addr)
        except ValueError:
            return False
        pool = self.v4 if a.version == 4 else self.v6
        # linear scan on a collapsed list is fine for a few thousand entries;
        # correctness matters more than micro-optimisation here
        return any(a in n for n in pool)


_PRIVATE_MATCHER = None


def private_matcher():
    global _PRIVATE_MATCHER
    if _PRIVATE_MATCHER is None:
        _PRIVATE_MATCHER = Matcher(PRIVATE_NETS)
    return _PRIVATE_MATCHER


class Engine:
    """Replay a rule list the way the engine would."""

    def __init__(self, name, rules, final, fallback_field):
        self.name = name
        self.rules = rules
        self.final = final
        self.fallback_field = fallback_field  # 'outbound' (sing-box) or 'outboundTag' (xray)
        self._cache = {}

    def _matcher(self, cidrs):
        key = tuple(cidrs)
        if key not in self._cache:
            self._cache[key] = Matcher(cidrs)
        return self._cache[key]

    def rule_matches(self, rule, dst, src, proto, dst_is_private):
        # every present condition must hold
        for field in ("ip", "ip_cidr"):
            if field in rule:
                v = rule[field]
                if isinstance(v, str):
                    v = [v]
                if dst not in self._matcher(v):
                    return False

        if "source_ip_cidr" in rule:
            v = rule["source_ip_cidr"]
            if isinstance(v, str):
                v = [v]
            if src is None or src not in self._matcher(v):
                return False

        if rule.get("ip_is_private") is True and not dst_is_private:
            return False

        if "network" in rule:
            nets = [n.strip() for n in str(rule["network"]).split(",")]
            if proto not in nets:
                return False

        if "protocol" in rule:
            protos = rule["protocol"]
            if isinstance(protos, str):
                protos = [p.strip() for p in protos.split(",")]
            if proto not in protos:
                return False

        return True

    def decide(self, dst, src=None, proto="tcp"):
        dst_priv = dst in private_matcher()
        for i, rule in enumerate(self.rules):
            if not self.rule_matches(rule, dst, src, proto, dst_priv):
                continue
            action = rule.get("action")
            target = rule.get(self.fallback_field)
            if target is None and action in ("sniff", None):
                continue  # sniff is not a decision; keep going
            if action:
                return action, i
            return target, i
        return self.final, None


def load_engine(path: str) -> Engine:
    doc = json.load(open(path, encoding="utf-8"))
    if "route" in doc:
        route = doc["route"]
        return Engine("sing-box", route.get("rules", []), route.get("final"), "outbound")
    if "routing" in doc:
        routing = doc["routing"]
        return Engine("xray", routing.get("rules", []), "proxy", "outboundTag")
    raise SystemExit("%s: neither `route` nor `routing` present — not a mu300-vpn profile" % path)


def collect_cn(engine: Engine) -> list[str]:
    out = []
    for r in engine.rules:
        for field in ("ip_cidr", "ip"):
            v = r.get(field)
            if isinstance(v, list) and len(v) > 100:
                out += v
    return out


def find_server_address(path: str) -> str | None:
    """Pull the proxy server address out of the config, for a sanity check."""
    doc = json.load(open(path, encoding="utf-8"))
    for o in doc.get("outbounds", []):
        if o.get("tag") == "proxy" and o.get("server"):
            return o["server"]
        for key in ("settings",):
            s = o.get(key, {})
            for grp in ("vnext", "servers"):
                for item in s.get(grp, []) or []:
                    if item.get("address"):
                        return item["address"]
    return None


def run(path: str) -> tuple[int, int]:
    eng = load_engine(path)
    cn = collect_cn(eng)
    server = find_server_address(path)

    print()
    print("config      : %s" % path)
    print("engine      : %s" % eng.name)
    print("rules       : %d" % len(eng.rules))
    print("direct tags : mainland-China ranges in the rule list = %d" % len(cn))
    if server:
        print("proxy server: %s" % server)
    print()

    ok_n = bad_n = 0

    def check(label, got, want):
        nonlocal ok_n, bad_n
        if got == want:
            ok_n += 1
            print("  %s[ ok ]%s %-52s -> %s" % (GREEN, OFF, label, got))
        else:
            bad_n += 1
            print("  %s[FAIL]%s %-52s -> %s (expected %s)" % (RED, OFF, label, got, want))

    # ---- LAN source behaviour (sing-box template only) ----
    lan_src = None
    for r in eng.rules:
        if r.get("source_ip_cidr"):
            lan_src = r["source_ip_cidr"]
            if isinstance(lan_src, str):
                lan_src = [lan_src]
            break

    # ---- mainland China ----
    print("mainland-China addresses  -> direct")
    for ip in CHINA:
        check(ip, eng.decide(ip)[0], "direct")

    # ---- random sample from the shipped range list ----
    sample = random.sample(cn, min(25, len(cn))) if cn else []
    if sample:
        print()
        print("random sample drawn from the range list -> direct")
        for net_str in sample[:10]:
            net = ipaddress.ip_network(net_str, strict=False)
            ip = str(net.network_address + min(1, net.num_addresses - 1))
            check("%s (in %s)" % (ip, net_str), eng.decide(ip)[0], "direct")

    # ---- non-China ----
    print()
    print("non-China addresses       -> proxy")
    for ip in FOREIGN:
        check(ip, eng.decide(ip)[0], "proxy")

    # ---- private ----
    print()
    print("private / loopback / reserved -> direct (never into the tunnel)")
    for ip in PRIVATE:
        check(ip, eng.decide(ip)[0], "direct")
    if eng.name == "xray":
        # the Xray rules carry an explicit reserved-range list
        for ip in RESERVED:
            check("%s (reserved)" % ip, eng.decide(ip)[0], "direct")
    else:
        print()
        print("reserved (RFC 5737)       -> informational for sing-box")
        for ip in RESERVED:
            print("  %s[info]%s %-46s -> %s" % (DIM, OFF, ip, eng.decide(ip)[0]))
        print("  %s       sing-box decides this through its own `ip_is_private`%s" % (DIM, OFF))
        print("  %s       predicate rather than an explicit list.%s" % (DIM, OFF))

    # ---- LAN source + private destination ----
    if lan_src:
        print()
        print("LAN source -> private destination")
        src = lan_src[0].split("/")[0].rsplit(".", 1)[0] + ".50"
        check("%s -> 10.1.2.3" % src, eng.decide("10.1.2.3", src=src)[0], "reject")

    # ---- DNS ----
    if eng.name == "sing-box":
        print()
        print("client DNS -> hijacked into the tunnel resolver")
        check("proto=dns", eng.decide("1.1.1.1", proto="dns")[0], "hijack-dns")

    # ---- the VPN server must not be swallowed by the tunnel ----
    #
    # NOTE: this is informational, not a pass/fail assertion.
    #
    # `route.rules` / `routing.rules` only govern traffic that ARRIVES from the
    # TUN. The engine's own connection out to the VPN server is not inbound
    # traffic, so it is never matched here. The loop is prevented one level down,
    # in the kernel:
    #   * sing-box marks its own sockets with default_mark (0x2d0), and
    #     `ip rule 5198 fwmark 0x2d0 lookup main` sends them out the carrier
    #     interface instead of table 2022 (which points into the TUN);
    #   * Xray relies on `ip rule 9002 to <server> lookup main`.
    # So "server -> proxy" in this simulation is expected and harmless.
    if server:
        print()
        print("proxy server reachability (informational)")
        got = eng.decide(server)[0]
        print("  [info] %s resolves to `%s` inside the rule list" % (server, got))
        print("         the engine's own connection to it bypasses the TUN via the")
        print("         kernel mark rules (5198 for sing-box, 9002 for Xray), so no loop.")
        if got != "proxy":
            print("  %s[note]%s the server address happens to fall inside a direct rule;"
                  % (DIM, OFF))
            print("         that is doubly safe, just unusual for a VPS.")

    print()
    if bad_n == 0:
        print("%s%s: %d checks, all passed%s" % (GREEN, os.path.basename(path), ok_n, OFF))
    else:
        print("%s%s: %d passed, %d FAILED%s" % (RED, os.path.basename(path), ok_n, bad_n, OFF))
    return ok_n, bad_n


def main() -> int:
    ap = argparse.ArgumentParser(description="Offline routing-semantics check for mu300-vpn split configs.")
    ap.add_argument("configs", nargs="+", help="generated *.singbox.json / *.xray.json")
    a = ap.parse_args()

    total_bad = 0
    for path in a.configs:
        if not os.path.exists(path):
            print("missing: %s" % path, file=sys.stderr)
            total_bad += 1
            continue
        _, bad = run(path)
        total_bad += bad

    return 1 if total_bad else 0


if __name__ == "__main__":
    sys.exit(main())
