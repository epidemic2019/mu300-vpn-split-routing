# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-10-13

First public release. Extracted and generalized from a working deployment on a
ZTE F50 (Unisoc T760) running mu300-linux's OpenWrt 25.12.5 with mu300-vpn.

### Added

- `scripts/gen-split-config.py` — generates a mu300-vpn profile that routes
  mainland-China destinations direct and everything else through the tunnel.
  Two modes: `--base` (reuse the device's own `gen` output, recommended) and
  `--uri` / `--uri-file` (build offline from a share link). Supports
  vless / vmess / trojan / shadowsocks, IPv6, custom LAN subnets, and emits both
  the sing-box and Xray forms.
- `scripts/sandbox-test.sh` — rehearses a deployment on the real device inside
  `/tmp` by redirecting `MU300_VPN_CONF` / `MU300_VPN_DIR` / `MU300_VPN_RUN`.
  Nothing outside the sandbox is read or written. Includes negative controls.
- `scripts/deploy.sh` — parameterized install with a pre-deploy snapshot,
  LAN-subnet configuration, device-side validation, and a dry-run mode.
- `scripts/verify.sh` — end-to-end proof from a LAN client and from the device,
  using the two exit addresses as a discriminator, plus an IPv6 leak probe.
- `scripts/backup.sh` / `scripts/restore.sh` — streamed backup of `/etc` with
  per-file hashes, and a restore path with `--verify` and `--dry-run`.
- `scripts/fetch-cn-cidrs.sh` — refresh the China IP range lists, with a
  `--check` mode and family/format validation.
- `tools/verify-routing.py` — offline routing-semantics verifier. Replays the
  rule list against known China / non-China / private addresses. No device and no
  network needed, so it runs in CI as a pre-deploy gate.
- Bilingual documentation (Chinese and English) covering the device constraints,
  the deployment procedure, and troubleshooting.
- GitHub Actions workflow running the generator self-check and the offline
  verifier on every push.

### Verified findings carried into the code

These were established experimentally against a real device, and each one
constrains the implementation:

- With the shipped defaults (`KILL_SWITCH=1`) and sing-box installed,
  `pick_engines` forces the engine to sing-box, so an Xray config is never
  loaded. Hence sing-box is the default output.
- A share-link profile gets hard-coded routing rules with no China-direct rule.
  Only a raw-config profile preserves custom `route.rules`.
- The Xray driver's inbound is a loopback SOCKS listener with no sniffing, so the
  engine never sees hostnames. Domain rules are dead code on that path; only IP
  ranges have any effect.
- `geoip:cn` is unavailable (no `geoip.dat` in the image), so China ranges must
  be inlined into the config.
- The rebuilt config must stay under 1 MiB, which the generator enforces.
- A CIDR sentinel written as a list element produces a nested array
  (`[[...]]`) when substituted, and the engine rejects the file. The generator
  asserts against this, and `tools/verify-routing.py` re-checks it.
- The DIRECT outbound needs a non-null `streamSettings` object, otherwise the
  device does not write `sockopt.mark` into it and the kill switch drops the
  "direct" traffic — direct becomes a black hole rather than a bypass.
- The device injects parameters that are easy to get wrong by hand
  (`packet_encoding: xudp`, DNS `type: tcp` with `detour: proxy`,
  `strategy: ipv4_only`, `default_domain_resolver: bootstrap`), which is why
  reusing the device's own `gen` output (`--base`) is the recommended mode.
- `mu300-vpn check` is a top-level subcommand: `mu300-vpn check <id>`, not
  `mu300-vpn profile check <id>`.
- `nft list ruleset` output changes on every read because of packet counters.
  Filter `counter packets` out before comparing two samples.
- Busybox `nc` on this image does not accept `-w` and yields false "unreachable"
  results. Do not use it for connectivity assertions.
- `exec 3<>/dev/tcp/<foreign-ip>/53` appears to succeed even when the target is
  unreachable, because sing-box's gvisor stack completes the handshake locally.
  It cannot be used to detect leaks; use the exit address instead.
- `mu300-power` stops the service when the modem drops but does not touch the
  enable flag; the kill switch survives a service stop by design. To actually
  stop the tunnel use `mu300-vpn off`, which also removes the kill switch.
