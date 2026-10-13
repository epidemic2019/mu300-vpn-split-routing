#!/bin/sh
# sandbox-test.sh — rehearse a deployment on the real device WITHOUT touching it.
#
#   ./sandbox-test.sh --host 192.168.1.1 --config out/split-cn.singbox.json
#   ./sandbox-test.sh --host 192.168.1.1 --config out/split-cn.singbox.json --with-xray
#
# mu300-vpn redirects all of its state through three environment variables:
#
#     MU300_VPN_CONF   path to vpn.conf
#     MU300_VPN_DIR    the profile store
#     MU300_VPN_RUN    the runtime directory
#
# Pointing those at a directory under /tmp gives a complete, isolated instance of
# the tool. The device's own /etc, /run, nft tables, kernel routes and service
# state are never read from or written to. The verdict is produced by the
# device's own `mu300-vpn`, `jq`, `xray -test` and `sing-box check` — not by this
# script's opinion of what a config should look like.
#
# This is how you find out that a config the device will reject is invalid BEFORE
# it is installed, and how you confirm the rebuild actually keeps your CN rules.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=lib-ssh.sh
. "$HERE/lib-ssh.sh"

HOST=""; PORT=22; USER=root; PASS=""
CONFIG=""; LAN="192.168.77.0/24"; WITH_XRAY=0; KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --host|-h)    HOST="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --user)       USER="$2"; shift 2 ;;
        --pass|-w)    PASS="$2"; shift 2 ;;
        --config)     CONFIG="$2"; shift 2 ;;
        --lan-cidrs)  LAN="$2"; shift 2 ;;
        --with-xray)  WITH_XRAY=1; shift ;;
        --keep)       KEEP=1; shift ;;
        --help)       sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$HOST" ] || { echo "error: --host <device-ip> is required" >&2; exit 2; }
[ -n "$CONFIG" ] || { echo "error: --config <generated.json> is required" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "error: not found: $CONFIG" >&2; exit 1; }

mu300_ssh_init --host "$HOST" --port "$PORT" --user "$USER" ${PASS:+--pass "$PASS"}

echo "device  : $MU300_USER@$MU300_HOST:$MU300_PORT"
echo "config  : ${CONFIG#"$ROOT"/} ($(wc -c < "$CONFIG") bytes)"
echo "sandbox : /tmp/mu300sandbox on the device (nothing outside it is touched)"
echo

echo "== upload =="
mu300_ssh 'rm -rf /tmp/mu300sandbox; mkdir -p /tmp/mu300sandbox/payload'
mu300_scp "$CONFIG" /tmp/mu300sandbox/payload/split.json
mu300_ssh 'wc -c < /tmp/mu300sandbox/payload/split.json' | sed 's/^/   /'

OUTFILE=$(mktemp)
trap 'rm -f "$OUTFILE"; mu300_ssh_cleanup' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# Device-side test battery, executed with the environment redirected to /tmp.
# ---------------------------------------------------------------------------
mu300_ssh "sh -s" > "$OUTFILE" 2>&1 <<REMOTE || true
set -u
SIM=/tmp/mu300sandbox
STORE=\$SIM/etc/mu300
RUNDIR=\$SIM/run
mkdir -p "\$STORE/vpn" "\$RUNDIR" "\$SIM/out"
printf 'ENABLE=0\n' > "\$STORE/vpn.conf"

PASS=0; FAIL=0
ok()  { PASS=\$((PASS+1)); printf '  [PASS] %s\n' "\$1"; }
no()  { FAIL=\$((FAIL+1)); printf '  [FAIL] %s\n' "\$1"; }
chk() { if [ "\$2" = "\$3" ]; then ok "\$1 => \$2"; else no "\$1 expected[\$3] got[\$2]"; fi; }
hd()  { printf '\n=== %s ===\n' "\$1"; }

vpn() { MU300_VPN_CONF="\$STORE/vpn.conf" MU300_VPN_DIR="\$STORE/vpn" MU300_VPN_RUN="\$RUNDIR" mu300-vpn "\$@"; }

hd "0. environment"
echo "  tool    : \$(readlink -f /usr/bin/mu300-vpn 2>/dev/null || command -v mu300-vpn)"
command -v xray   >/dev/null 2>&1 && echo "  xray    : \$(xray version 2>/dev/null | head -1)"
command -v sing-box >/dev/null 2>&1 && echo "  sing-box: \$(sing-box version 2>/dev/null | head -1)"
command -v jq     >/dev/null 2>&1 && echo "  jq      : \$(jq --version 2>/dev/null)"
echo "  sandbox : \$SIM  (MU300_VPN_CONF / MU300_VPN_DIR / MU300_VPN_RUN redirected)"

hd "1. settings currently in effect (read-only)"
for k in KILL_SWITCH IPV6 TAILSCALE REMOTE_DNS BOOTSTRAP_DNS LAN_CIDRS; do
    printf '  %-14s = %s\n' "\$k" "\$(vpn settings get "\$k" 2>/dev/null)"
done

hd "2. import + check the candidate config"
rm -rf "\$STORE/vpn/profiles/cand"
if vpn profile import "\$SIM/payload/split.json" cand >"\$SIM/tmp.txt" 2>&1; then
    ok "profile import accepted the file"
else
    no "profile import REJECTED it: \$(tail -1 "\$SIM/tmp.txt" | cut -c1-160)"
fi
if vpn profile use cand >/dev/null 2>&1 && vpn check cand >"\$SIM/tmp.txt" 2>&1; then
    ok "mu300-vpn check passed"
else
    no "mu300-vpn check FAILED: \$(tail -1 "\$SIM/tmp.txt" | cut -c1-160)"
fi

hd "3. gen: what the engine will actually be handed"
rm -f "\$RUNDIR/config.json" "\$RUNDIR/xray.json"
if vpn gen >"\$SIM/tmp.txt" 2>&1; then
    ok "gen succeeded against the real engine binaries"
else
    no "gen FAILED: \$(grep -iE 'error|fail|refus' "\$SIM/tmp.txt" | head -1 | cut -c1-160)"
fi

if [ -f "\$RUNDIR/config.json" ]; then
    f=\$RUNDIR/config.json
    cp "\$f" "\$SIM/out/rebuilt-singbox.json"
    printf '  top keys : %s\n' "\$(jq -r 'keys_unsorted|join(",")' "\$f")"
    printf '  TUN      : %s\n' "\$(jq -c '.inbounds[0]|{type,stack,interface_name,auto_route,strict_route,route_exclude_address}' "\$f")"
    printf '  route    : final=%s default_mark=%s rules=%s\n' \
        "\$(jq -r '.route.final' "\$f")" "\$(jq -r '.route.default_mark' "\$f")" "\$(jq -r '.route.rules|length' "\$f")"
    chk "kill switch mark forced to 720"        "\$(jq -r '.route.default_mark' "\$f")" "720"
    chk "auto_route enabled"                    "\$(jq -r '.inbounds[0].auto_route' "\$f")" "true"
    chk "LAN excluded from the TUN"             "\$(jq -r '.inbounds[0].route_exclude_address[0]' "\$f")" "$LAN"
    CN=\$(jq -r '[.route.rules[]|select(.ip_cidr!=null)][0].ip_cidr|length' "\$f")
    if [ "\$CN" -gt 1000 ] 2>/dev/null; then ok "CN range list survived the rebuild (\$CN entries)"
    else no "CN range list looks wrong (\$CN entries)"; fi
    FINAL=\$(jq -r '.route.final' "\$f")
    chk "catch-all goes to the tunnel"          "\$FINAL" "proxy"
else
    no "sing-box config.json was not produced"
fi

if [ "$WITH_XRAY" = 1 ]; then
    hd "4. Xray path (only meaningful with KILL_SWITCH=0)"
    rm -f "\$RUNDIR/xray.json"
    if vpn profile use cand >/dev/null 2>&1 && vpn gen >"\$SIM/tmp.txt" 2>&1 && [ -f "\$RUNDIR/xray.json" ]; then
        f=\$RUNDIR/xray.json
        cp "\$f" "\$SIM/out/rebuilt-xray.json"
        n=\$(jq -r '[.outbounds[]]|length' "\$f")
        m=\$(jq -r '[.outbounds[]|select(.streamSettings.sockopt.mark==720)]|length' "\$f")
        chk "every outbound carries mark 720" "\$m/\$n" "\$n/\$n"
        chk "CN ranges intact" "\$(jq -r '[.routing.rules[]|select(.ip!=null)][-1].ip|length' "\$f")" \
            "\$(jq -r '[.routing.rules[]|select(.ip!=null)][-1].ip|length' "\$SIM/payload/split.json")"
    else
        no "xray.json was not produced (expected when KILL_SWITCH=1 and sing-box is installed)"
    fi
fi

hd "5. negative controls (each must be refused)"
mkdir -p "\$SIM/neg"
printf '%s' '{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"},"brand-new-key":1}' \
    > "\$SIM/neg/bad-topkey.json"
rm -rf "\$STORE/vpn/profiles/neg1"
if vpn profile import "\$SIM/neg/bad-topkey.json" neg1 >"\$SIM/tmp.txt" 2>&1; then
    no "a config with an unknown top-level key was ACCEPTED (whitelist not enforced?)"
else
    ok "unknown top-level key refused: \$(grep -iE 'refus|not |unknown' "\$SIM/tmp.txt" | head -1 | cut -c1-120)"
fi

printf '%s' '{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[{"ip_cidr":["1.1.1.0/24"],"outbound":"nope"}],"final":"direct"}' \
    > "\$SIM/neg/bad-rule-tag.json"
rm -rf "\$STORE/vpn/profiles/neg2"
if vpn profile import "\$SIM/neg/bad-rule-tag.json" neg2 >"\$SIM/tmp.txt" 2>&1 \
   && vpn check neg2 >"\$SIM/tmp.txt" 2>&1; then
    no "a rule pointing at a non-existent outbound was ACCEPTED"
else
    ok "dangling outbound reference refused"
fi

hd "6. is a geo database even present?"
ls /mnt/mu300-disk/extra/vpn/bin/ 2>/dev/null | grep -iE 'geo|\.dat' \
    && echo "  ^ geo data found (geoip:cn may be usable)" \
    || echo "  no .dat / geo files -> geoip:/geosite: rules cannot work; inline CIDR lists are required"

hd "summary"
printf '  PASS=%s  FAIL=%s\n' "\$PASS" "\$FAIL"
REMOTE

cat "$OUTFILE"

echo
if [ "$KEEP" = 1 ]; then
    echo "== results kept on the device =="
    echo "   /tmp/mu300sandbox/out/  (post-rebuild configs)"
else
    echo "== clean up =="
    mu300_ssh 'rm -rf /tmp/mu300sandbox; echo "   removed /tmp/mu300sandbox"'
fi

if grep -q 'FAIL=0' "$OUTFILE"; then
    echo
    echo "sandbox rehearsal passed — the config is safe to deploy."
    exit 0
fi
echo
echo "sandbox rehearsal reported failures — do NOT deploy until they are resolved." >&2
exit 1
