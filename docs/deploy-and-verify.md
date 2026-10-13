# Deploy and verify

[← Back to README](../README.en.md) · [中文](部署与验证.md)

A complete runbook. Each step lists the **expected output** so you can compare.

---

## Prepare

```sh
cd mu300-vpn-split-routing
chmod +x scripts/* tools/*

DEV=192.168.77.1        # your device
LAN=192.168.77.0/24     # the device's LAN subnet; confirm with `mu300-vpn settings get LAN_CIDRS`
```

You need `ssh` / `scp` / `curl` and Python 3.9+ locally. Supply the password with
`--pass`, `$MU300_PASS`, or interactively.

---

## Step 1 — Back up first

**Do this before anything else.** Even if nothing later works, you will at least be
able to roll back.

```sh
scripts/backup.sh --host $DEV
```

Expected:

```
device  : root@192.168.77.1:22
scope   : all
into    : .../backups/f50-20261013-101500

  -> etc.tar.gz
     334 entries, 182872 bytes
  -> uci.txt
  -> netstate.txt
  -> state.txt
     288 files hashed
  -> vpn-status.txt

done.
  etc.tar.gz sha256 = 3f2a...
  manifest          = .../backups/f50-20261013-101500/MANIFEST.md
```

**This directory is sensitive.** It contains your node URI, `/etc/shadow`, and the
dropbear host keys.

---

## Step 2 — Take a base config from the device (recommended)

The device parses your node parameters more accurately than anything else will.

```sh
ssh root@$DEV 'MU300_VPN_RUN=/tmp/gen mu300-vpn gen >/dev/null 2>&1; cat /tmp/gen/config.json' \
  > device-base.json
```

Expected (excerpt):

```json
{
  "log": { "level": "warn", "timestamp": false },
  "dns": { "servers": [
      { "type": "tcp", "tag": "remote", "server": "1.1.1.1", "detour": "proxy" },
      { "type": "udp", "tag": "bootstrap", "server": "1.1.1.1" } ],
    "final": "remote", "strategy": "ipv4_only" },
  "inbounds": [ { "type": "tun", … "route_exclude_address": [ "192.168.77.0/24" ] } ],
  "outbounds": [ { "type": "vless", "tag": "proxy", "server": "...",
                   "flow": "xtls-rprx-vision", "packet_encoding": "xudp", … },
                 { "type": "direct", "tag": "direct" } ],
  "route": { "rules": [ { "action": "sniff" }, … ], "final": "proxy",
             "default_mark": 720, "auto_detect_interface": true }
}
```

> This writes to `/tmp` only. `/etc` is untouched.

**Cannot do this step?** Skip it and use `--uri` in the next step.

---

## Step 3 — Generate

```sh
# recommended
python3 scripts/gen-split-config.py \
    --base device-base.json \
    --lan-cidrs $LAN

# or fully offline
python3 scripts/gen-split-config.py \
    --uri-file my-node.uri \
    --lan-cidrs $LAN
```

Expected:

```
mainland-China IPv4 : 7456 ranges after collapsing
mainland-China IPv6 : not included (--ipv6 to add)
LAN subnet          : 192.168.77.0/24

[sing-box] source : device-base.json
           dropped top-level keys: log, inbounds
           replaced 4 existing template rule(s)
[sing-box] rules  :
           [0] {"action": "sniff"}
           [1] {"protocol": "dns", "action": "hijack-dns"}
           [2] {"source_ip_cidr": "<192.168.77.0/24>", "ip_is_private": true, "action": "reject"}
           [3] {"ip_is_private": true, "outbound": "direct"}
           [4] {"ip_cidr": "<7456 ranges>", "outbound": "direct"}
[sing-box] final  : proxy
[xray    ] source : share link (offline mapping; loaded only when KILL_SWITCH=0)

split-cn.singbox.json                             141737 bytes  OK
split-cn.xray.json                                141835 bytes  OK

self-check : passed (no nested arrays, no refused keys, every outbound / detour resolves, within size limit)
```

> The line `replaced N existing template rule(s)` only appears in `--base` mode.
> The device's own output already contains the template rules (sniff / hijack-dns /
> LAN reject / private direct); the generator replaces them rather than stacking on
> top, so nothing is evaluated twice.

A failed self-check prints the reasons and exits non-zero **without writing any
output file**.

---

## Step 4 — Offline semantics check

```sh
python3 tools/verify-routing.py out/split-cn.singbox.json out/split-cn.xray.json
```

Expected (excerpt):

```
config      : out/split-cn.singbox.json
engine      : sing-box
rules       : 5
direct tags : mainland-China ranges in the rule list = 7456

mainland-China addresses  -> direct
  [ ok ] 114.114.114.114                                      -> direct
  …
non-China addresses       -> proxy
  [ ok ] 8.8.8.8                                              -> proxy
  …
private / loopback / reserved -> direct (never into the tunnel)
  [ ok ] 10.0.0.1                                             -> direct
  …
LAN source -> private destination
  [ ok ] 192.168.77.50 -> 10.1.2.3                            -> reject
client DNS -> hijacked into the tunnel resolver
  [ ok ] proto=dns                                            -> hijack-dns
proxy server reachability (informational)
  [info] 223.0.103.1 resolves to `proxy` inside the rule list
         the engine's own connection to it bypasses the TUN via the
         kernel mark rules (5198 for sing-box, 9002 for Xray), so no loop.

split-cn.singbox.json: 50 checks, all passed
```

> `ip_is_private` is defined by sing-box itself, so for **sing-box** configs the
> RFC 5737 reserved addresses are reported informationally; only the **Xray**
> config (which carries an explicit reserved list) asserts them.

---

## Step 5 — Rehearse on the device

Validate with the device's own engines, entirely inside `/tmp`:

```sh
scripts/sandbox-test.sh --host $DEV --config out/split-cn.singbox.json
```

Expected (excerpt):

```
== upload ==
   141737
=== 0. environment ===
  tool    : /opt/mu300/bin/mu300-vpn
  xray    : Xray 26.3.27
  sing-box: sing-box version 1.14.1 (with_gvisor)
  jq      : jq-1.8.1
  sandbox : /tmp/mu300sandbox  (MU300_VPN_CONF / MU300_VPN_DIR / MU300_VPN_RUN redirected)

=== 2. import + check the candidate config ===
  [PASS] profile import accepted the file
  [PASS] mu300-vpn check passed
  [PASS] gen succeeded against the real engine binaries
  [PASS] kill switch mark forced to 720
  [PASS] auto_route enabled
  [PASS] LAN excluded from the TUN
  [PASS] CN range list survived the rebuild (7456 entries)
  [PASS] catch-all goes to the tunnel

=== 5. negative controls (each must be refused) ===
  [PASS] unknown top-level key refused: …
  [PASS] dangling outbound reference refused

=== 6. is a geo database even present? ===
  no .dat / geo files -> geoip:/geosite: rules cannot work; inline CIDR lists are required

=== summary ===
  PASS=10  FAIL=0

sandbox rehearsal passed — the config is safe to deploy.
```

**If you see `FAIL=` anything but zero, stop here.**

---

## Step 6 — Deploy

Dry run first:

```sh
scripts/deploy.sh --host $DEV --lan-cidrs $LAN --dry-run
```

It prints **every command it intends to run** and changes nothing. Once you are
happy, drop `--dry-run`:

```sh
scripts/deploy.sh --host $DEV --lan-cidrs $LAN
```

What it does:

```
== 0. safety snapshot on the device ==   tar czf /tmp/mu300-predeploy-<time>.tar.gz -C / etc/mu300 etc/config
== 1. tunnel off ==                      mu300-vpn off
== 2. LAN subnet ==                      mu300-vpn settings set LAN_CIDRS '<LAN>'
== 3. upload + import ==                 scp -> /tmp/mu300-split.json
                                         mu300-vpn profile import … split-cn
                                         mu300-vpn profile use split-cn
== 4. device-side validation ==          mu300-vpn check split-cn
== 6. tunnel on ==                       mu300-vpn on
                                         mu300-vpn status
```

Expected `status`:

```
profile: split-cn (sing-box)  enabled: 1  kill switch: 1 (active)
engine : sing-box
tunnel : sbtun 172.19.0.1/30
exit IP: <your VPN server IP>
```

> **It writes to `/etc`.** The change set should be: one new profile directory, plus
> `active`, `vpn.conf` and `settings` — **nothing deleted, and your original
> profile untouched.**

---

## Step 7 — Real network verification

Run this **on a LAN client**:

```sh
scripts/verify.sh --host $DEV
```

If the VPN server's egress is its own address you can be stricter:

```sh
scripts/verify.sh --host $DEV --vpn-server <server-ip> --direct-exit <your-carrier-ip>
```

Expected (excerpt):

```
== 1. exit addresses ==
  [info] direct exit (mainland-China echo) : 223.x.x.x
  [info] VPN exit    (non-China echo)      : 192.0.2.10
  [ ok ] two distinct exits: 223.x.x.x (direct) vs 192.0.2.10 (VPN)

== 2. LAN client (192.168.77.106/24) ==
-- mainland-China targets: expect the DIRECT exit --
  http://ip.3322.net/                            HTTP=200
  [ ok ] reachable
  …
-- tunnel-dependent sites: reachable only through the VPN --
  https://www.google.com                         200|84769
  [ ok ] reachable via tunnel
  …

== 3. the device itself ==
-- mainland-China targets --
  http://ip.3322.net/                            -> 223.x.x.x
  [ ok ] direct
-- non-China targets --
  http://ifconfig.me/ip                          -> 192.0.2.10
  [ ok ] via VPN

== 5. IPv6 leak probe ==
  [ ok ] IPv6 blocked (https://api64.ipify.org)

summary
  ok=24  fail=0
```

Three things matter:

1. **the two exit addresses must differ**, otherwise the split is not in effect;
2. **a domestic echo returns your carrier IP**, proving China traffic really is direct;
3. **every IPv6 probe must fail**, otherwise there is a leak.

---

## Step 8 — Watch it for a few minutes

```sh
ssh root@$DEV '
  for i in 1 2 3 4 5; do
    printf "%s  " "$(date +%H:%M:%S)"
    mu300-vpn enabled | tr -d "\n"; printf "  "
    nft list table inet mu300_vpn >/dev/null 2>&1 && printf "killswitch=up  " || printf "killswitch=DOWN  "
    printf "iface=%s  " "$(cat /run/mu300-vpn/iface 2>/dev/null)"
    printf "exit=%s\n" "$(wget -4 -qO- -T 8 http://ifconfig.me/ip 2>/dev/null || echo fail)"
    sleep 30
  done'
```

Every line should be identical.

---

## Rollback

### Light: switch back to the original profile

```sh
ssh root@$DEV "
  mu300-vpn profile use <your-original-profile>
  mu300-vpn settings set LAN_CIDRS ''
"
```

This toolkit only **adds** a profile and never modifies yours, so this path is
usually sufficient.

### Full: restore from a backup

```sh
# see what would change
scripts/restore.sh --dir backups/f50-<timestamp> --host $DEV --verify
scripts/restore.sh --dir backups/f50-<timestamp> --host $DEV --dry-run

# restore for real (VPN parts only)
scripts/restore.sh --dir backups/f50-<timestamp> --host $DEV --yes --only etc/mu300
```

Before overwriting anything, `restore.sh` saves the **current** `/etc/mu300` to
`/tmp/mu300-prerestore-<time>.tar.gz`, so a mistaken restore is itself reversible.
It also compares sha256 after uploading and aborts on a mismatch.

---

## Changing nodes / refreshing the ranges

```sh
# new node
ssh root@$DEV "
  mu300-vpn profile add <type> <name> '<new link>'
  mu300-vpn profile use <name>
  MU300_VPN_RUN=/tmp/gen mu300-vpn gen"
ssh root@$DEV 'cat /tmp/gen/config.json' > new-base.json

python3 scripts/gen-split-config.py --base new-base.json --name split-cn-v2
scripts/sandbox-test.sh --host $DEV --config out/split-cn-v2.singbox.json
scripts/deploy.sh --host $DEV --config out/split-cn-v2.singbox.json --profile split-cn-v2

# refresh the ranges
scripts/fetch-cn-cidrs.sh
python3 scripts/gen-split-config.py --base device-base.json
scripts/deploy.sh --host $DEV
```

---

[← Back to README](../README.en.md) · Something wrong? See [Troubleshooting](troubleshooting.md)
