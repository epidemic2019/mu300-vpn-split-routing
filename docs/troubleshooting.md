# Troubleshooting

[← Back to README](../README.en.md) · [中文](故障排查.md)

Organised as **symptom → what to check first → cause → fix**.

---

## Generation stage

### The generator's self-check fails

**Symptom**

```
SELF-CHECK FAILED:
  - nested array detected at .route.rules[4].ip_cidr[0] — the sentinel must be the entire value, not an element of a list
```

or

```
  - contains refused key(s): listen, listen_port
```

**Cause**

- Nested array: the CIDR placeholder was written as a list element. After
  substitution it becomes `[[...]]`, and the engine rejects the file with
  `unknown format of a string list`.
- Refused key: the config contains a field the device strips or would
  misinterpret (`listen`, `redirect`, `override_address`, …).

**Fix**

Do not hand-edit the generated CIDR block. If you must assemble a config
yourself, remember the placeholder has to be the **entire value**, not an element:

```jsonc
"ip": ["__MU300_CN_CIDRS__"]   // ✗ becomes [[...]]
"ip": "__MU300_CN_CIDRS__"     // ✓
```

### No China ranges were read

**Symptom**: `error: no IPv4 ranges read from .../data/cn-ipv4.txt`

**Fix**: run `scripts/fetch-cn-cidrs.sh`. If the machine has no outbound access,
copy the file over from somewhere that does — the format is one CIDR per line.

---

## Installation stage

### `profile import` is rejected

**Look at the real reason first**; the device's message is readable:

```sh
mu300-vpn profile import out/split-cn.singbox.json probe 2>&1 | tail -3
```

| Message contains | Cause | Fix |
|---|---|---|
| `top-level key` | a key outside the whitelist | the generator only emits `dns` / `outbounds` / `route`; remove extras if you hand-edited |
| `larger` / `1 MiB` | file too large | only happens if you inlined extra data by hand |
| `unknown format of a string list` | nested array | see above |
| `not allowed` / `refus` | a refused key | remove `listen` / `redirect` / `override_address` etc. |

> To decide whether something was *really* rejected, use `mu300-vpn check <ID>` —
> a **top-level** subcommand. `mu300-vpn profile check <ID>` prints a usage error
> and also exits non-zero, so using it as the criterion gives a false pass.

### `mu300-vpn check` is rejected

```
route.final=proxy is not a known outbound [direct]
```

or

```
rules[3].outbound=direct is not in outbounds [proxy]
```

**Cause**: `route.rules[].outbound` and `route.final` must resolve to some
`outbounds[].tag`. The device asserts this rule by rule.

**Fix**: check that `outbounds` contains `tag: "direct"` and `tag: "proxy"` with
matching spelling and case.

---

## Runtime stage

### The tunnel is up, but nothing foreign works

Check in order:

```sh
# 1. is the engine running, is the TUN there
ssh root@$DEV 'ps w | grep -E "[s]ing-box|[x]ray"; ip link show sbtun 2>/dev/null'

# 2. does the tunnel actually connect (engine log)
ssh root@$DEV 'logread | grep -iE "sing-box|vless|outbound" | tail -20'

# 3. can the device reach the server at all
ssh root@$DEV 'ping -c3 -W3 <server-ip>'
```

**The most likely cause is wrong proxy parameters in `outbounds`.**

This is precisely why you should not transcribe them by hand: a Reality public key
missing one character, an omitted `flow`, or a `server_name` that does not match
the server all present as "timeout" with no useful error.

**Fix**: go back to `--base` and let the device generate `outbounds`:

```sh
ssh root@$DEV 'MU300_VPN_RUN=/tmp/gen mu300-vpn gen >/dev/null 2>&1; cat /tmp/gen/config.json' > device-base.json
python3 scripts/gen-split-config.py --base device-base.json
```

### Domestic traffic is going through the VPN

**Judge by exit address**, not by "baidu feels fast":

```sh
scripts/verify.sh --host $DEV
```

| Possible cause | Check | Fix |
|---|---|---|
| the China rule is not present | `direct tags` count in `tools/verify-routing.py` output | should be 7456; zero means the ranges were not read |
| the rule was lost during rebuild | `CN range list survived the rebuild` in `sandbox-test.sh` | if it fails, the profile is in `uri` form instead of `config.json` |
| the destination is not inside the China ranges | see below | see below |
| the hostname resolved to a foreign IP first | see the next section | see the next section |

**The last one is the most common** — the predicate is the **destination IP**, and a
hostname has to resolve before it can be judged.

### A domestic site is treated as foreign

**Symptom**: a domestic site's traffic exits through the VPN server.

**Cause**: the device's and the LAN's DNS is pulled into the tunnel by
`hijack-dns`, so answers are resolved from the tunnel exit's point of view. Domestic
CDNs schedule by resolver location and occasionally hand back a foreign node, which
then fails the "mainland China" test.

**Verify**

```sh
python3 - <<'PY'
import ipaddress
nets=[ipaddress.ip_network(l.strip(),strict=False) for l in open('data/cn-ipv4.txt') if l.strip()]
ip=ipaddress.ip_address("put the resolved IP here")
print("inside the China ranges" if any(ip in n for n in nets) else "outside → will be treated as foreign")
PY
```

**Fix** (two options, in order of preference)

1. **Change the in-tunnel resolver**: point the `remote` entry in `dns.servers` at a
   China-resident DNS (e.g. `223.5.5.5`). The query still leaves through the tunnel,
   but the answer carries a domestic point of view.
2. **Add a domain-direct rule**: insert
   `{ "domain_suffix": [".example.cn"], "outbound": "direct" }` **before** the China
   range rule. Note this only has any effect on the sing-box path (the one that
   sniffs); the Xray path never sees hostnames, so the rule would be dead code there.

### The split is not in effect: both exits show the same IP

```sh
scripts/verify.sh --host $DEV
```

If the two addresses match, everything is taking one path. Check each:

| Check | Expected |
|---|---|
| `profile` in `mu300-vpn status` | `split-cn` (sing-box), not your original share-link profile |
| the active file | `cat /etc/mu300/vpn/active` says `split-cn` |
| the config actually running | `cat /run/mu300-vpn/config.json \| jq '.route.rules \| length'` should be ≥ 5 |
| the China rule | `jq '.route.rules[-1].ip_cidr \| length' /run/mu300-vpn/config.json` should be ~7456 |

**If `/run/mu300-vpn/config.json` has no China rule**, the device is not loading your
config. The usual reason is a profile in `uri` form (hard-coded routing) rather than
`config.json` form. `sandbox-test.sh` catches this before deployment.

### IPv6 is leaking

```sh
scripts/verify.sh --host $DEV        # includes the IPv6 probes by default
```

Expected: **every IPv6 probe fails.**

On the device you should see:

```sh
ssh root@$DEV 'ip -6 rule show | head -3'
# 9000:   from all unreachable
```

⚠️ **Do not judge leaks with `exec 3<>/dev/tcp/8.8.8.8/53`.** For a TUN-routed
destination, sing-box's gvisor stack completes the three-way handshake **locally**,
so it looks connected while nothing leaves the device. Judge by exit address and the
IPv6 probes.

### The tunnel gets switched off by itself (`ENABLE` flips to 0, kill switch removed)

**Symptom**

```sh
cat /etc/mu300/vpn.conf      # ENABLE=0
nft list tables              # no `table inet mu300_vpn`
ls /etc/rc.d/ | grep vpn     # the symlink is gone
```

**Meaning**: `mu300-vpn off` was executed (its `off)` branch runs `svc disable`,
which removes the rc.d link). During that window LAN traffic egresses **in the
clear**.

**Investigate**

```sh
ssh root@$DEV '
  echo "-- any dropbear sessions?"; logread | grep dropbear | tail -5
  echo "-- mu300-power state dir (absent = its VPN logic never ran) --"; ls -d /run/mu300-power 2>/dev/null
  echo "-- who calls off --"; grep -rn "mu300-vpn off" /opt/mu300/bin /etc/init.d /etc/hotplug.d 2>/dev/null
  echo "-- web panel --"; netstat -ltnp 2>/dev/null | grep -E ":80|:443"
'
```

**What is already established**

| Component | Behaviour |
|---|---|
| `/etc/init.d/mu300-vpn stop` | does **not** remove the kill switch (by design: a crash never leaks); and `respawn` restarts it in ~5 s |
| `mu300-power` | only stops the *service* when the modem drops; it does **not** write `ENABLE` |
| device scripts | the only caller of `set_enable 0` is the `off)` branch of `mu300-vpn`; no script invokes it |
| the web panel (`uhttpd` on 80/443) | can call `mu300-vpn` over ubus/CGI — the only remaining entry point |

**Suggestion**: disable the panel or move its port and watch for a recurrence. If it
recurs while the tunnel is unhealthy, the component is actively turning the VPN off
when it cannot reach the server — which contradicts its own fail-closed design and is
worth reporting upstream.

**Recover**:

```sh
ssh root@$DEV 'mu300-vpn on && mu300-vpn status'
```

### SSH to the device stops working after deployment

**Do not panic.** The kill switch only affects the **outbound** direction on
`sipa_eth*` and `wlan0`. SSH arrives over `br-lan` and is unaffected. The only real
risk in the flow is that `deploy.sh` runs `mu300-vpn off` (which removes the kill
switch) — but that also does not affect LAN-side SSH.

If you genuinely cannot connect:

1. ping the device from another machine on the **same LAN**;
2. check that `LAN_CIDRS` was not set to a subnet that excludes your client — that
   would make the `reject` rule drop it (though the TUN's `route_exclude_address`
   normally keeps LAN traffic out of the tunnel anyway);
3. as a last resort use serial or recovery mode, and restore from the step-1 backup.

**Prevention**: the `LAN_CIDRS` that `deploy.sh` sets in step 2 must match the subnet
your clients actually use.

---

## Observing and measuring

### `nft list ruleset` differs between two reads

The `counter packets` counters move. Filter them out before comparing:

```sh
nft list ruleset | grep -v 'counter packets'
```

### The device has no `tcpdump` and no `curl`

Only busybox `wget`. Use it like this:

```sh
# exit address
wget -4 -qO- -T 15 http://ifconfig.me/ip

# a domestic echo
wget -4 -qO- -T 15 http://ip.3322.net
```

Note that busybox `nc` does **not** accept `-w` (`nc [IPADDR PORT]` is the valid
form), so using it for connectivity assertions yields false "unreachable".

### Which path does a specific host take?

Test by IP, bypassing DNS:

```sh
curl -4 -s --resolve ifconfig.me:80:198.51.100.7 http://ifconfig.me/ip
curl -4 -s --resolve ip.3322.net:80:118.184.169.32 http://ip.3322.net/
```

The first should return the VPN exit, the second your carrier exit.

### Is a given IP inside the China ranges?

```sh
python3 - <<'PY'
import ipaddress
nets=[ipaddress.ip_network(l.strip(),strict=False) for l in open('data/cn-ipv4.txt') if l.strip()]
ip=ipaddress.ip_address("8.8.8.8")
hit=[str(n) for n in nets if ip in n]
print(hit or "not inside the China ranges")
PY
```

---

## Performance

### Domestic access is slow too

**Symptom**: domestic sites take about as long as foreign ones (seconds).

**Meaning**: domestic traffic is detouring abroad. Confirm with the exit address
above.

**If the exit address is correct but it is still slow**: it could be rule-matching
cost. 7456 CIDRs is a linear scan on paper, but sing-box optimises rule sets
internally; measured figures were ~0.09 s domestic and ~1.0 s foreign, a difference
roughly equal to the tunnel RTT. That is the expected magnitude.

---

## Still stuck?

Collect this and the problem is usually pinned down:

```sh
# on the device
ssh root@$DEV '
  mu300-vpn status
  mu300-vpn settings get
  mu300-vpn profile list
  echo "-- rules --"; jq ".route.rules | map(if .ip_cidr then . + {ip_cidr: (.ip_cidr|length)} else . end)" /run/mu300-vpn/config.json
  echo "-- kernel --"; ip rule show; ip route show table 2022 | head
  nft list tables
  echo "-- log --"; logread | grep -iE "sing-box|vpn" | tail -30
'
```

plus locally:

```sh
python3 tools/verify-routing.py out/split-cn.singbox.json
scripts/sandbox-test.sh --host $DEV --config out/split-cn.singbox.json --keep
```

**Redact before posting**: replace the server IP, the UUID, and the Reality public key.

---

[← Back to README](../README.en.md)
