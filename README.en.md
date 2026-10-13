# mu300-vpn split routing

**Route mainland-China destinations direct and everything else through the VPN — on a ZTE F50 (Unisoc T760) running mu300-linux's OpenWrt.**

[中文](README.md) · [How it works](docs/how-it-works.md) · [Deploy & verify](docs/deploy-and-verify.md) · [Troubleshooting](docs/troubleshooting.md)

---

## Contents

- [What this is](#what-this-is)
- [Why a naive config does not work](#why-a-naive-config-does-not-work)
- [The decision chain](#the-decision-chain)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Scripts](#scripts)
- [What the generated config looks like](#what-the-generated-config-looks-like)
- [Three layers of verification](#three-layers-of-verification)
- [Backup and rollback](#backup-and-rollback)
- [FAQ](#faq)
- [Repository layout](#repository-layout)
- [Security notes](#security-notes)
- [Data sources and credits](#data-sources-and-credits)

---

## What this is

`mu300-vpn` is designed as a **whole-device full tunnel with a kill switch**. It
has no traffic-splitting of its own: everything goes into the tunnel, and if the
tunnel drops, packets are dropped too. That is safe, but it also means your
domestic traffic takes a round trip through a foreign server.

This toolkit opens a split without modifying `mu300-vpn` itself, by exploiting a
property of its sing-box driver:

> The driver accepts profiles in the **raw configuration** form. In that form the
> `route.rules` you write are **preserved verbatim** — only `inbounds` is replaced
> with the device's own TUN. So appending a single "mainland China → direct" rule
> turns the catch-all `final: proxy` into "everything else goes through the VPN".

The resulting behaviour:

| Destination | Path | Exit address |
|---|---|---|
| Mainland China | direct | your carrier / cellular IP |
| Anywhere else | tunnel | the VPN server IP |
| Private / loopback / link-local | direct | never leaves the device |
| LAN client to another private range | rejected | never enters the tunnel |

## Why a naive config does not work

Writing a config straight from the sing-box documentation will simply have no
effect on this device. Every constraint below was established experimentally, and
each one changed the implementation:

| Constraint | What was measured | Consequence |
|---|---|---|
| The engine is forced | With the shipped `KILL_SWITCH=1` and sing-box installed, `pick_engines` **rewrites the engine to sing-box** | An Xray config written to `routing.rules` is **never loaded at all** |
| Share-link profiles have hard-coded routing | `gen_singbox()` emits only `sniff → hijack-dns → LAN+private reject → private direct`, `final: proxy` — **no China-direct rule whatsoever** | China-direct requires the raw-config profile form |
| The engine never sees hostnames | The Xray driver's inbound is a loopback SOCKS listener with no sniffing; `hev-socks5-tunnel` only relays IP packets | `domain:` rules are **dead code**; the only usable predicate is the IP range |
| `geoip:cn` is unavailable | No `geoip.dat` in the image | All 7456 ranges must be **inlined** into the config |
| 1 MiB profile limit | Larger files are rejected outright | Inlined output lands at ~141 KB — fine, but it must be checked |
| The direct outbound needs a mark | The device only writes `sockopt.mark=720` into outbounds that **already have a `streamSettings` object** | Omit `streamSettings` on the direct outbound and the kill switch drops it — "direct" silently becomes a black hole |
| The device overwrites parameters | It forces `inbounds`, `route.default_mark=720`, `auto_detect_interface`, and appends its own bootstrap DNS entry | Hand-transcribing the proxy parameters is error-prone |

That last point is the important one: **do not transcribe the parameters by
hand.** The recommended workflow asks the device to generate a base config for
you (`mu300-vpn gen`), then injects the routing rules into it — so the Reality
public key, `flow`, `packet_encoding`, DNS `strategy` and everything else match
what the device expects, byte for byte.

## The decision chain

What the sing-box engine actually evaluates, in order:

```
packet ──▶ TUN (sbtun, 172.19.0.1/30)
             │
             ├─ ① action: sniff ─────────────── no decision, protocol detection only
             ├─ ② protocol: dns → hijack-dns ── client DNS is pulled into the tunnel
             ├─ ③ src∈LAN and dst∈private → reject
             ├─ ④ dst∈private/loopback/reserved → direct
             ├─ ⑤ dst∈mainland China (7456) → direct
             │                                  engine connects itself, marked 0x2d0
             │                                  → kernel rule 5198 → main table
             │                                  → out the cellular interface
             └─ ⑥ final: proxy ──────────────── VLESS tunnel → VPN server
```

LAN traffic never reaches the TUN at all: its subnet is listed in
`route_exclude_address`.

## Requirements

| Item | Value |
|---|---|
| Device | ZTE F50 / MU300 (Unisoc T760) |
| Firmware | mu300-linux's OpenWrt (measured on OpenWrt 25.12.5, aarch64) |
| Component | `mu300-vpn` (the `vpn` extra), sing-box 1.14+ / Xray 26+ |
| Local tools | POSIX `sh`, `ssh`, `scp`, `curl`, Python 3.9+ |
| Node | any `vless` / `vmess` / `trojan` / `shadowsocks` share link |

> On other OpenWrt devices the same approach applies provided `mu300-vpn`'s
> profile semantics are unchanged — but re-confirm `pick_engines`, the profile
> whitelist, and the kill-switch rules for your build.

## Quick start

### 0. Get the code

```sh
git clone <this-repo> mu300-vpn-split-routing
cd mu300-vpn-split-routing
chmod +x scripts/* tools/*
```

### 1. (Recommended) Fetch a base config from the device

Run `gen` on the device once. It writes to `/tmp` only and never touches `/etc`:

```sh
ssh root@<device-ip>
  MU300_VPN_RUN=/tmp/gen mu300-vpn gen
  cat /tmp/gen/config.json
```

Save that as `device-base.json` locally.

> **Why this extra step is worth it:** `gen` expands your node parameters into
> `outbounds` using the device's own parser. Using its output as the base removes
> a whole class of "off by one character / missing flow / wrong DNS strategy"
> problems that only surface as a tunnel that will not connect.
>
> If you cannot do this, `--uri` builds the config fully offline instead. See
> [FAQ](#no-device-access).

### 2. Generate the config

```sh
# Recommended: from the device base
python3 scripts/gen-split-config.py --base device-base.json

# Or: fully offline, from a share link
python3 scripts/gen-split-config.py \
    --uri-file examples/node.example.uri \
    --lan-cidrs 192.168.77.0/24
```

Output:

```
out/split-cn.singbox.json     <- the default engine (what actually runs at KILL_SWITCH=1)
out/split-cn.xray.json        <- only used when KILL_SWITCH=0
```

**`--lan-cidrs` is optional in `--base` mode.** The device's own output already
carries the LAN subnet in `route_exclude_address`, and the generator reads it back
out — more reliable than typing it:

```
LAN subnet          : 192.168.77.0/24  (read back from the base config's route_exclude_address)
```

Offline mode (`--uri`) has nothing to read it from, so it falls back to the F50
stock value and tells you to verify it against
`mu300-vpn settings get LAN_CIDRS`.

### 3. Offline self-check

No device, no network access needed:

```sh
python3 tools/verify-routing.py out/split-cn.singbox.json
```

It replays the rule list and asserts China → `direct`, non-China → `proxy`,
private → `direct`.

### 4. Rehearse on the device (zero side effects)

`mu300-vpn` redirects all of its state through `MU300_VPN_CONF` /
`MU300_VPN_DIR` / `MU300_VPN_RUN`. Pointing those at a directory under `/tmp`
gives a complete isolated instance — the device's `/etc`, kernel routes, nft
tables and service state are untouched:

```sh
scripts/sandbox-test.sh --host 192.168.77.1 --config out/split-cn.singbox.json
```

### 5. Deploy

```sh
scripts/deploy.sh --host 192.168.77.1 --lan-cidrs 192.168.77.0/24 --dry-run
scripts/deploy.sh --host 192.168.77.1 --lan-cidrs 192.168.77.0/24
```

The password comes from `--pass`, `$MU300_PASS`, or an interactive prompt.
**Nothing is hard-coded anywhere in this repository.**

### 6. Verify

Run this from a **LAN client** of the device (it also tests the device itself):

```sh
scripts/verify.sh --host 192.168.77.1
```

## Scripts

| Script | Purpose | Modifies the device? |
|---|---|---|
| `scripts/gen-split-config.py` | Generate the split config (`--base` or `--uri`) | No |
| `scripts/fetch-cn-cidrs.sh` | Refresh the China range lists (`--check` compares only) | No |
| `tools/verify-routing.py` | Offline routing-semantics check; CI-friendly | No |
| `scripts/sandbox-test.sh` | Rehearse in `/tmp` using the device's real engines | No (all under `/tmp`) |
| `scripts/deploy.sh` | Install the profile, set the LAN subnet, toggle the tunnel | **Yes** (`--dry-run` to preview) |
| `scripts/verify.sh` | Real network test plus an IPv6 leak probe | No |
| `scripts/backup.sh` | Streamed `/etc` backup with per-file hashes | No (read-only) |
| `scripts/restore.sh` | Roll back; supports `--verify` / `--dry-run` | **Yes** |
| `scripts/lib-ssh.sh` | Shared SSH plumbing (askpass; password never in argv) | — |

## What the generated config looks like

```jsonc
{
  "dns": { /* copied verbatim from the device's gen output */ },
  "outbounds": [
    { "type": "vless", "tag": "proxy", "server": "203.0.113.10", /* … */ },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "source_ip_cidr": ["192.168.77.0/24"], "ip_is_private": true, "action": "reject" },
      { "ip_is_private": true, "outbound": "direct" },
      { "ip_cidr": [ /* 7456 mainland-China ranges */ ], "outbound": "direct" }  // ← injected
    ],
    "final": "proxy"                                                            // ← rest via VPN
  }
}
```

See [`examples/split-cn.example.jsonc`](examples/split-cn.example.jsonc) for an
annotated version.

During the rebuild the device adds:

```jsonc
"inbounds": [{
  "type": "tun", "tag": "tun-in", "stack": "gvisor", "interface_name": "sbtun",
  "address": ["172.19.0.1/30"], "mtu": 1400,
  "auto_route": true, "strict_route": true,
  "route_exclude_address": ["192.168.77.0/24"]     // ← LAN stays out of the tunnel
}],
"route": { "default_mark": 720, "auto_detect_interface": true,   // 720 = 0x2d0
           "default_domain_resolver": "bootstrap" }
```

## Three layers of verification

| Layer | Command | Evidence | Device needed |
|---|---|---|---|
| ① Offline semantics | `tools/verify-routing.py` | replays the rule list, asserts each decision | No |
| ② Device rehearsal | `scripts/sandbox-test.sh` | the device's own `mu300-vpn check` / `sing-box check` / `xray -test` | Yes (read-only, `/tmp`) |
| ③ Real network | `scripts/verify.sh` | **the two exit addresses as a discriminator** | Yes |

Layer ③ works because a split has exactly two possible exits, so one China IP-echo
service and one foreign IP-echo service settle the question:

- China echo returns your carrier IP, foreign echo returns the VPN server IP → the split works
- both return the same address → the split is not in effect

This is not a heuristic: **the exit address is either one or the other, there is
no third possibility.**

`verify.sh` also probes for IPv6 leaks — with the tunnel up, any IPv6 egress
should fail.

## Backup and rollback

```sh
# Back up first
scripts/backup.sh --host 192.168.77.1

# Look without touching
scripts/restore.sh --dir backups/f50-<timestamp> --host 192.168.77.1 --verify
scripts/restore.sh --dir backups/f50-<timestamp> --host 192.168.77.1 --dry-run

# Actually roll back (VPN parts only)
scripts/restore.sh --dir backups/f50-<timestamp> --host 192.168.77.1 --yes --only etc/mu300
```

A backup contains all of `/etc`, `uci export`, the network state, and per-file
md5s. Before overwriting anything, the current `/etc/mu300` is saved to `/tmp` on
the device — so **even a mistaken restore is itself reversible.**

A lighter rollback is usually enough, because this toolkit never modifies your
existing profile — it only adds one:

```sh
mu300-vpn profile use <your-original-profile>
mu300-vpn settings set LAN_CIDRS ''
```

## FAQ

<a id="no-device-access"></a>
<details>
<summary><b>What if I have no access to the device?</b></summary>

Generate fully offline with `--uri` / `--uri-file`:

```sh
python3 scripts/gen-split-config.py --uri-file my-node.uri --lan-cidrs 192.168.1.0/24
```

This maps the share link's query parameters onto sing-box outbound fields. It
covers `vless` / `vmess` / `trojan` / `shadowsocks` over `raw` / `ws` / `grpc` /
`httpupgrade` transports and the `tls` / `reality` security layers. A few exotic
combinations may still be incomplete, so **once you can reach the device, prefer
regenerating with `--base`.**
</details>

<details>
<summary><b>Why is sing-box the default instead of Xray?</b></summary>

Because the device would ignore an Xray config. `pick_engines` contains:

```sh
if [ "$ENGINE" = xray ] && [ "$KILL_SWITCH" = 1 ] && [ -x "$BIN" ]; then ENGINE=sing-box; fi
```

`KILL_SWITCH=1` is the factory default, so any share-link profile ends up on
sing-box. To genuinely use the Xray engine you must turn the kill switch off —
which also gives up the fail-closed guarantee. `deploy.sh --engine xray` warns
about this explicitly and asks for confirmation.
</details>

<details>
<summary><b>Can I split by domain name?</b></summary>

Not on this device. The Xray driver's inbound is a loopback SOCKS listener with
no sniffing, and `hev-socks5-tunnel` only relays IP packets — **the engine never
sees a hostname.** A `domain:` rule would be written but never matched, so the
only usable predicate is the IP range.

The sing-box path does enable `action: sniff`, but its splitting rules are also
IP-based; keeping both paths consistent is more predictable.
</details>

<details>
<summary><b>A domestic CDN site resolves to a foreign IP and goes through the VPN. What now?</b></summary>

This does happen: your DNS query is pulled into the tunnel, so the answer is
resolved from the tunnel exit's point of view, and some domestic sites get
scheduled to foreign nodes.

Mitigations: use a China-resident resolver inside the tunnel, or edit the config
after generation to insert a `domain:` direct rule **before** the China range
rule. Note this only has any effect on the sing-box path (the one that sniffs).

See [troubleshooting](docs/troubleshooting.md#a-domestic-site-is-treated-as-foreign).
</details>

<details>
<summary><b>Do I need to regenerate after updating the IP ranges?</b></summary>

Yes. The China ranges are **inlined** into the config, not looked up at runtime.

```sh
scripts/fetch-cn-cidrs.sh                     # refresh the data
python3 scripts/gen-split-config.py --base device-base.json
scripts/sandbox-test.sh --host <device-ip> --config out/split-cn.singbox.json
scripts/deploy.sh       --host <device-ip>
```

IP delegation for China changes slowly; monthly is plenty.
</details>

<details>
<summary><b>I changed nodes (new share link). Now what?</b></summary>

Ask the device for a new base config from the new link, then regenerate:

```sh
# on the device
mu300-vpn profile add <type> <name> '<new link>'
mu300-vpn profile use <name>
MU300_VPN_RUN=/tmp/gen mu300-vpn gen     # take /tmp/gen/config.json

# locally
python3 scripts/gen-split-config.py --base new-base.json --name split-cn-v2
scripts/deploy.sh --host <device-ip> --config out/split-cn-v2.singbox.json --profile split-cn-v2
```
</details>

<details>
<summary><b>The tunnel is up but IPv6 seems to leak?</b></summary>

Test with the IPv6 probes in `scripts/verify.sh`. On the device, sing-box installs
`ip -6 rule 9000: from all unreachable`, and LAN-side IPv6 egress is dropped by
the kill switch's `forward` chain.

⚠️ Do not judge leaks with `exec 3<>/dev/tcp/8.8.8.8/53` or similar: for a
destination that goes through the TUN, **sing-box's gvisor stack completes the
handshake locally**, so it looks "connected" while nothing left the device. Judge
by exit address.
</details>

<details>
<summary><b>Why does <code>nft list ruleset</code> differ between two reads?</b></summary>

The `counter packets` counters move. Filter them out before comparing:

```sh
nft list ruleset | grep -v 'counter packets'
```
</details>

## Repository layout

```
.
├── README.md                 Chinese, primary
├── README.en.md              this file
├── CHANGELOG.md
├── LICENSE                   MIT
├── .github/workflows/ci.yml  generator self-check + offline verification + leak scan
├── data/
│   ├── cn-ipv4.txt           mainland-China IPv4 ranges (7456)
│   ├── cn-ipv6.txt           mainland-China IPv6 ranges
│   └── SOURCES.md            provenance and how to refresh
├── docs/
│   ├── 原理与设备约束.md       why it has to be done this way (Chinese)
│   ├── how-it-works.md        (this language)
│   ├── 部署与验证.md           full runbook (Chinese)
│   ├── deploy-and-verify.md   (this language)
│   ├── 故障排查.md            (Chinese)
│   └── troubleshooting.md     (this language)
├── examples/
│   ├── node.example.uri      share-link template (all placeholders)
│   ├── device-base.example.json
│   └── split-cn.example.jsonc
├── scripts/                  generate / deploy / verify / backup / restore
└── tools/verify-routing.py   offline routing-semantics verifier
```

## Security notes

- **Backups and generated configs are sensitive.** They contain your node address
  and UUID; backups additionally contain `/etc/shadow` and the dropbear host keys.
  Treat them like passwords. `.gitignore` excludes them by default.
- **This toolkit does not weaken the kill switch.** With the default
  `KILL_SWITCH=1` it stays effective end to end: a dropped tunnel means dropped
  packets, not plaintext fallthrough. `--engine xray` requires turning it off and
  warns accordingly.
- **`mu300-vpn off` removes the kill switch**, after which traffic egresses in the
  clear. `/etc/init.d/mu300-vpn stop` will not hold it down — `respawn` brings it
  back within about 5 seconds.
- **`deploy.sh` writes to `/etc`.** Run it with `--dry-run` first to see exactly
  what it intends to do.

## Data sources and credits

| Data | Source | Licence |
|---|---|---|
| Mainland-China IPv4 ranges | [17mon/china_ip_list](https://github.com/17mon/china_ip_list) | MIT |
| Mainland-China IPv6 ranges | [gaoyifan/china-operator-ip](https://github.com/gaoyifan/china-operator-ip) | MIT |

The copies under `data/` are snapshots; refresh them with
`scripts/fetch-cn-cidrs.sh` (`--check` reports whether an update exists). See
[`data/SOURCES.md`](data/SOURCES.md).

The engine-behaviour findings come from inspecting and exercising the real
scripts and binaries on a mu300-linux device (`bin/mu300-vpn`, `lib/vpn/*.sh`,
`xray`, `sing-box`) — not from documentation.

## License

[MIT](LICENSE)
