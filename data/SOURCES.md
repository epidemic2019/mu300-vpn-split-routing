# Data sources

`data/cn-ipv4.txt` and `data/cn-ipv6.txt` list the IP ranges delegated to
mainland China. They are **snapshots**, committed so that a clone can generate a
config without network access.

## Provenance

| File | Upstream | Refresh URL |
|---|---|---|
| `cn-ipv4.txt` | [17mon/china_ip_list](https://github.com/17mon/china_ip_list) | `https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt` |
| `cn-ipv6.txt` | [gaoyifan/china-operator-ip](https://github.com/gaoyifan/china-operator-ip) | `https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china6.txt` |

Both upstreams derive their lists from the APNIC delegation records, so they track
the actual allocation of address space to China rather than a curated guess.

| File | Ranges | Purpose |
|---|---|---|
| `cn-ipv4.txt` | 7456 | the list injected into `route.rules` |
| `cn-ipv6.txt` | 3473 | only used with `--ipv6` (needed when the device has `mu300-vpn settings IPV6=1`) |

## Why the ranges are inlined instead of using `geoip:cn`

The upstream engines can normally reference a geo database by name:

```jsonc
{ "ip": ["geoip:cn"], "outboundTag": "direct" }
```

That does **not** work here. The mu300-linux image ships no `geoip.dat` /
`geosite.dat` in `/mnt/mu300-disk/extra/vpn/bin/`, and Xray rejects the config
with a lookup failure. You can confirm the absence on your own device:

```sh
ls /mnt/mu300-disk/extra/vpn/bin/ | grep -iE 'geo|\.dat'   # expects no output
```

So the ranges have to be written into the config literally. That is also why the
generated file is ~141 KB: the list dominates it. It stays well under the
device's 1 MiB profile limit.

## Refreshing

```sh
scripts/fetch-cn-cidrs.sh            # download and replace
scripts/fetch-cn-cidrs.sh --check    # report whether the snapshot is stale
```

The script validates every downloaded line — it must parse as a CIDR of the
expected address family — and refuses to overwrite the committed copy if
validation fails. After refreshing, regenerate and redeploy:

```sh
python3 scripts/gen-split-config.py --base device-base.json
scripts/sandbox-test.sh --host <device-ip> --config out/split-cn.singbox.json
scripts/deploy.sh       --host <device-ip>
```

IPv4 delegation for China changes on the order of a few ranges per quarter, so a
monthly refresh is more than enough.

## Caveats

- **The list is a routing aid, not a security boundary.** It says "this address
  is allocated to a Chinese network", which is not the same as "this host is in
  China and is safe to reach directly". Ranges do get re-delegated.
- **`cn-ipv6.txt` is usually unnecessary.** With the device's default `IPV6=0`,
  the TUN carries no IPv6 address, so IPv6 rules can never match. Pass `--ipv6`
  only if you have enabled IPv6 on the device.
- **Overlaps are expected and harmless.** The generator merges duplicates and
  adjacent ranges with `ipaddress.collapse_addresses()` before writing.

## Licence

Both upstream projects are MIT-licensed. Their lists are redistributed here as
data with attribution; see the repository `LICENSE` for the code.
