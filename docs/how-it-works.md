# How it works, and why

[← Back to README](../README.en.md) · [中文](原理与设备约束.md)

This document explains **why** the toolkit has to look the way it does. Every
conclusion below comes from inspecting and exercising the real scripts and
binaries on the device (`bin/mu300-vpn`, `lib/vpn/*.sh`, `xray`, `sing-box`) —
not from upstream documentation.

---

## 1. What mu300-vpn is designed to do

`mu300-vpn` is a **fail-closed full tunnel**. Its goals are:

1. push all egress traffic — the device's own and the LAN's — into the tunnel;
2. guarantee with a kill switch that **a dropped tunnel means dropped packets**,
   never a fallback to plaintext egress.

There is no concept of splitting anywhere in that design. It even guarantees that
the kill switch **survives a service stop**, so a crashed process cannot leak.

Splitting is therefore not a toggle. It requires finding an injection point the
engine will actually accept.

## 2. There are two engine paths

| | Xray path | sing-box path |
|---|---|---|
| Trigger | a share-link profile with `KILL_SWITCH=0` | `KILL_SWITCH=1` (default), or any raw-config profile |
| Engine | `xray` + `hev-socks5-tunnel` | `sing-box` |
| Routing | `DRV_ROUTES=core`: kernel `ip rule` + `table 2022` push everything into `xtun` | `DRV_ROUTES=self`: sing-box's `auto_route` installs its own rules, own TUN `sbtun` |
| Inbound | loopback SOCKS; `hev-socks5-tunnel` translates IP packets into SOCKS | TUN (gvisor stack, `172.19.0.1/30`) |
| Sniffing | **no** | yes (rules contain an explicit `action: sniff`) |

### 2.1 The engine is forced

`pick_engines` contains:

```sh
if [ "$ENGINE" = xray ] && [ "$KILL_SWITCH" = 1 ] && [ -x "$BIN" ]; then ENGINE=sing-box; fi
```

With default settings and sing-box installed, **the engine is always sing-box.** An
Xray config you write is not "ineffective" — it is never read at all.

Corroborating observation on the device: `/run/mu300-vpn/iface` contained `sbtun`.

### 2.2 Consequence

| Approach | Outcome |
|---|---|
| Share-link profile, hoping to add rules | `gen_singbox()`'s routing is **hard-coded**; there is no seam |
| A native Xray JSON | with the default `KILL_SWITCH=1` it is **never loaded** |

## 3. The two profile forms

The sing-box driver accepts two:

| File | Generator | Where the routing rules come from |
|---|---|---|
| `$PDIR/uri` (share link) | `gen_singbox()` | **hard-coded**: `sniff → hijack-dns → LAN+private reject → private direct`, `final: proxy`. **No China-direct rule at all** |
| `$PDIR/config.json` (raw config) | `gen_singbox_json()` → `singbox_json_rebuild()` | **your own `route.rules` are preserved**; only specific keys are overridden |

That is the only seam: the **raw-config** form.

### 3.1 What the rebuild stage does

Keys preserved at the top level: `dns`, `outbounds`, `route`, `endpoints`.
(`log`, `inbounds`, `experimental` are dropped or replaced.)

Keys preserved under `route`: `rules`, `rule_set`, `final`, `default_domain_resolver`.
Anything else under `route` is dropped.

Forced overrides:

```jsonc
"inbounds": [{                       // replaced entirely by the device's own TUN
  "type": "tun", "tag": "tun-in", "stack": "gvisor",
  "interface_name": "sbtun", "address": ["172.19.0.1/30"], "mtu": 1400,
  "auto_route": true, "strict_route": true,
  "route_exclude_address": ["<LAN_CIDRS>"]
}],
"route": {
  "default_mark": 720,               // = 0x2d0, the only mark the kill switch passes
  "auto_detect_interface": true,
  "default_domain_resolver": "bootstrap"
},
"dns": { "servers": [ /* … , */ {"type":"udp","tag":"mu300-bootstrap","server":"…"} ] }
```

Plus an assertion: every `route.rules[].outbound` and `route.final` must resolve
to some `outbounds[].tag`, or the file is rejected.

### 3.2 What that implies for the implementation

- The rule list must be written **in full**. The device's template rules
  (sniff / hijack-dns / private reject) are **not** injected on the raw-config path.
- The proxy parameters in `outbounds` must match what the device expects. The
  device overrides `inbounds` but *not* `outbounds`, so a small mistake breaks the
  tunnel outright.
- Which is exactly why `--base` is the recommended mode: **let the device produce
  `outbounds`, and only append rules.**

## 4. The constraints, one by one

### 4.1 The engine never sees a hostname

The Xray driver's inbound is a loopback SOCKS listener with no sniffing:

```jsonc
"inbounds": [{ "protocol": "socks", "listen": "127.0.0.1", "port": 10808 }]
```

`hev-socks5-tunnel` only translates IP packets into SOCKS connections. Nothing in
that chain ever resolves a hostname.

**Consequence:** `domain:` rules are dead code on this device. The only usable
predicate is the IP range.

### 4.2 `geoip:cn` is unavailable

There is no `geoip.dat` / `geosite.dat` in the image. A config referencing
`geoip:cn` fails at the `xray -test` stage and the engine refuses to start.

**Consequence:** all 7456 China ranges must be **inlined** into the JSON.

### 4.3 The 1 MiB profile limit

Files above 1 MiB are rejected. Inlining 7456 IPv4 ranges (plus optionally 3473
IPv6) yields roughly 141 KB — comfortable.

### 4.4 The direct outbound must carry a mark

The device only writes `sockopt.mark=720` into outbounds whose `streamSettings` is
**already an object**:

```sh
# pseudocode
if (.streamSettings | type) == "object" then
    .streamSettings.sockopt.mark = 720
end
```

So a direct outbound that omits `streamSettings` never receives a mark, and the
kill switch drops its packets.

> **"Direct" without a mark is not direct. It is a black hole.**

The generated direct outbound therefore looks like this — the empty
`streamSettings` object is load-bearing:

```jsonc
{ "tag": "direct", "protocol": "freedom",
  "settings": { "domainStrategy": "UseIP" }, "streamSettings": {} }
```

### 4.5 The CIDR sentinel must occupy the whole value

The generator uses `__MU300_CN_CIDRS__` as a placeholder and substitutes a
nicely formatted multi-line CIDR block at render time. Written as a list element:

```jsonc
"ip": ["__MU300_CN_CIDRS__"]      // ✗ becomes [[...]] after substitution
```

substituting the quoted token produces a **nested array**, and the engine reports:

```
unknown format of a string list: [[ "0.0.0.0/8", ...
```

The correct form lets the sentinel be the entire value:

```jsonc
"ip": "__MU300_CN_CIDRS__"        // ✓
```

After rendering, the generator re-parses the output and walks it to confirm **no
array contains another array**.

### 4.6 `check` is a top-level subcommand

```
mu300-vpn check <ID>
```

not `mu300-vpn profile check <ID>`. The latter prints a usage error and exits
non-zero — so using it as a "negative sample was rejected" assertion produces a
**false pass** (the script concludes "rejected" when the command was simply
malformed).

### 4.7 Other measured details

| Observation | Note |
|---|---|
| `nft list ruleset` differs between reads | `counter packets` moves. Filter with `grep -v 'counter packets'` before comparing |
| Busybox `nc` does not accept `-w` | `nc [IPADDR PORT]` is the valid form; using `-w` yields false "unreachable" |
| `exec 3<>/dev/tcp/8.8.8.8/53` appears to connect | for a TUN-routed destination, **sing-box's gvisor stack completes the handshake locally**. It cannot detect leaks |
| No `tcpdump`, no `curl` on the device | only busybox `wget` |
| `/etc/init.d/mu300-vpn stop` does not hold | `procd_set_param respawn 3600 5 0` restarts it in ~5 s. To stop it for real use `mu300-vpn off` — which also removes the kill switch |
| A service stop leaves the kill switch up | by design: a crash never leaks |
| `mu300-power` calls `vpn_stop` when the modem drops | but it only stops the service and does **not** write `ENABLE`; and if its state directory is absent the logic never fired |

## 5. Runtime kernel structure

The split decision happens in **userspace** (inside sing-box). The kernel's only
jobs are to get traffic into the TUN and to let the engine's own connections
bypass it.

```
ip rule
  5198:  fwmark 0x2d0 lookup main          <- the engine's own packets → main table → carrier
  9000:  to 172.19.0.0/30 lookup 2022      <- destination inside the TUN subnet
  9001:  lookup 2022 suppress_prefixlength 0
  9002:  dns → main / iif sbtun goto 9010
  9003:  iif lo → 2022
  9010:  nop

table 2022: 0.0.0.0/1, 128.0.0.0/2 … all via 172.19.0.2 dev sbtun
            192.168.77.0/24 excluded

nft table inet mu300_vpn        <- kill switch
  chain output/forward: oifname "sipa_eth*" meta mark 0x2d0 accept
                        everything else drop

ip -6 rule
  9000: from all unreachable    <- IPv6 closed (installed by sing-box)
```

The important part: **the engine's own connection bypasses the TUN via
`mark 0x2d0`, not via `route.rules`.** Therefore:

- there is no loop even when the VPN server address falls outside every `direct`
  rule (the usual case);
- conversely, `route.rules` only governs traffic **arriving from the TUN**.

## 6. The full data flow

Take one LAN client request, to a domestic host and then a foreign one:

```
① DNS
   client -> device DNS -> rule ② hijack-dns -> the in-tunnel resolver
   (so answers carry the tunnel exit's point of view — see troubleshooting)

② domestic target 223.0.103.X (assume it is inside a China range)
   LAN packet -> br-lan -> (not excluded? then it stays local)
             -> TUN sbtun -> sing-box route.rules
                ④ private? no
                ⑤ inside the 7456 China ranges? yes -> outbound: direct
             -> sing-box connects itself via the direct outbound, socket marked 720
             -> kernel rule 5198 -> main table -> sipa_eth0 -> carrier
   exit IP = carrier IP

③ foreign target 198.51.100.x
   LAN packet -> TUN sbtun -> route.rules
                ④ private? no   ⑤ China? no
             -> final: proxy
             -> VLESS tunnel -> the VPN server
   exit IP = the VPN server IP
```

The two exits are mutually exclusive — which is the whole basis of
`scripts/verify.sh`.

## 7. Why it cannot be simplified

A natural thought: "sing-box has `auto_route`; why not just hand it the China
ranges and be done?"

You can — that is precisely what this toolkit does. The difficulty is entirely in
the **parameters**:

- in `outbounds`, the Reality public key, `short_id`, `server_name`, `flow`,
  `packet_encoding` and `utls.fingerprint` must all be right. One wrong character
  and the tunnel simply times out, with no useful error;
- the `dns` block's combination of `type: tcp`, `detour: proxy`, `final: remote`
  and `strategy: ipv4_only` is the shape the device generates, not something to
  invent;
- `domain_resolver: bootstrap` depends on the second DNS server's `tag`; renaming
  it breaks the chain.

So the least-effort correct path is: **let the device generate, then change only
the rules.** That is the sole reason `--base` exists.

---

[← Back to README](../README.en.md) · Next: [Deploy & verify](deploy-and-verify.md)
