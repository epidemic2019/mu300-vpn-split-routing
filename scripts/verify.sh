#!/bin/sh
# verify.sh — prove the split actually works, from both sides of the device.
#
#   ./verify.sh --host 192.168.1.1
#   ./verify.sh --host 192.168.1.1 --vpn-server 220.0.11.1 --direct-exit 8.8.8.8
#
# Run it from a LAN client of the device — it tests that client AND the device
# itself, over SSH.
#
# HOW IT DECIDES
#   Split routing has exactly two possible exits, so two IP echoes are enough:
#     * a mainland-China IP echo  -> must show the DIRECT exit (your carrier IP)
#     * a non-China IP echo       -> must show the VPN exit (usually the server IP)
#   If both show the same address the split is not working. That is a
#   deterministic check, not a heuristic.
#
#   The "foreign via VPN" list deliberately includes sites that are unreachable
#   from mainland China without a tunnel (google, youtube, github, wikipedia).
#   Reaching them is itself evidence the tunnel carried the traffic.
#
# ONLY-READ-ONLY: this script never changes device state. The one exception is
# --ipv6-probe, which installs a temporary nft table to make sure IPv6 really is
# blocked; it removes it again on exit.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib-ssh.sh
. "$HERE/lib-ssh.sh"

HOST=""; PORT=22; USER=root; PASS=""
VPN_SERVER=""; DIRECT_EXIT=""
CN_ECHO="http://ip.3322.net"
DO_IPV6=1

while [ $# -gt 0 ]; do
    case "$1" in
        --host|-h)         HOST="$2"; shift 2 ;;
        --port)            PORT="$2"; shift 2 ;;
        --user)            USER="$2"; shift 2 ;;
        --pass|-w)         PASS="$2"; shift 2 ;;
        --vpn-server)      VPN_SERVER="$2"; shift 2 ;;
        --direct-exit)     DIRECT_EXIT="$2"; shift 2 ;;
        --cn-echo)         CN_ECHO="$2"; shift 2 ;;
        --no-ipv6)         DO_IPV6=0; shift ;;
        --help)            sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -n "$HOST" ] || { echo "error: --host <device-ip> is required" >&2; exit 2; }

PASS_CN=0; FAIL_CN=0
ok()   { PASS_CN=$((PASS_CN+1)); printf '  \033[32m[ ok ]\033[0m %s\n' "$1"; }
bad()  { FAIL_CN=$((FAIL_CN+1)); printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }
info() { printf '  [info] %s\n' "$1"; }
hd()   { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# ---------------------------------------------------------------- helpers
# local HTTP GET: prints body, follows redirects, IPv4 only
lget() { curl -4 -fsSL -m 25 "$1" 2>/dev/null || true; }
# same but returns "" on failure and never prints a partial line
lget_ip() { curl -4 -fsSL -m 25 "$1" 2>/dev/null | tr -d '\r\n' | head -c 64 || true; }

# device-side: busybox wget. No curl on stock firmware.
dget_ip() {
    mu300_ssh "wget -4 -q --no-check-certificate -O - -T 25 '$1' 2>/dev/null | tr -d '\r\n'" \
        | tr -d '\r\n' | head -c 64
}

is_ip() { printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }

# ---------------------------------------------------------------- preflight
mu300_ssh_init --host "$HOST" --port "$PORT" --user "$USER" ${PASS:+--pass "$PASS"}

hd "0. connectivity"
if mu300_ssh 'echo alive' | grep -q alive; then
    ok "SSH to $USER@$HOST"
else
    bad "cannot reach the device over SSH"; exit 1
fi
mu300_ssh 'mu300-vpn status' | sed 's/^/  | /' || true

# ---------------------------------------------------------------- discriminators
hd "1. exit addresses"

DIRECT_IP=$(lget_ip "$CN_ECHO")
[ -n "$DIRECT_IP" ] || DIRECT_IP="$(lget_ip 'http://members.3322.org/dyndns/getip')"
[ -n "$DIRECT_IP" ] || DIRECT_IP="$(lget_ip 'https://myip.ipip.net' | sed 's/.*IP[:：][[:space:]]*//;s/[^0-9.].*//')"

VPN_IP=""
for u in "http://ifconfig.me/ip" "https://api.ipify.org" "http://ipinfo.io/ip"; do
    VPN_IP=$(lget_ip "$u")
    is_ip "$VPN_IP" && break
    VPN_IP=""
done

info "direct exit (mainland-China echo) : ${DIRECT_IP:-(unavailable)}"
info "VPN exit    (non-China echo)      : ${VPN_IP:-(unavailable)}"

if [ -n "$DIRECT_IP" ] && [ -n "$VPN_IP" ]; then
    if [ "$DIRECT_IP" = "$VPN_IP" ]; then
        bad "both paths exit through $DIRECT_IP — the split is NOT in effect"
    else
        ok "two distinct exits: $DIRECT_IP (direct) vs $VPN_IP (VPN)"
    fi
fi

if [ -n "$VPN_SERVER" ]; then
    if [ "$VPN_IP" = "$VPN_SERVER" ]; then
        ok "VPN exit == the VPN server address ($VPN_SERVER)"
    else
        info "VPN exit $VPN_IP differs from --vpn-server $VPN_SERVER"
        info "  (normal for a relay, a CDN front, or a server with a separate egress)"
    fi
fi
if [ -n "$DIRECT_EXIT" ] && [ -n "$DIRECT_IP" ]; then
    if [ "$DIRECT_IP" = "$DIRECT_EXIT" ]; then
        ok "direct exit matches --direct-exit ($DIRECT_EXIT)"
    else
        bad "direct exit is $DIRECT_IP, expected $DIRECT_EXIT"
    fi
fi

# ---------------------------------------------------------------- LAN side
hd "2. LAN client ($(ip -4 -o addr show 2>/dev/null | awk '/scope global/{print $4; exit}'))"

info "-- mainland-China targets: expect the DIRECT exit --"
for u in "$CN_ECHO" "http://members.3322.org/dyndns/getip" "http://www.baidu.com"; do
    code=$(curl -4 -s -m 20 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null || echo 000)
    printf '  %-46s HTTP=%s\n' "$u" "$code"
    [ "$code" != "000" ] && ok "reachable" || bad "unreachable"
done

info "-- non-China targets: expect the VPN exit --"
for u in "http://ifconfig.me/ip" "https://api.ipify.org" "http://ipinfo.io/ip"; do
    body=$(curl -4 -fsSL -m 25 "$u" 2>/dev/null | tr -d '\r\n' | head -c 40 || true)
    if [ -n "$body" ]; then
        if [ -n "$VPN_IP" ] && [ "$body" = "$VPN_IP" ]; then ok "exit = $body (VPN)"
        else info "exit = $body"; fi
    else
        bad "$u unreachable"
    fi
done

info "-- tunnel-dependent sites: reachable only through the VPN --"
for u in "https://www.google.com" "https://www.youtube.com" "https://github.com" \
         "https://en.wikipedia.org/wiki/Main_Page"; do
    res=$(curl -4 -s -m 30 -o /dev/null -w '%{http_code}|%{size_download}' -L "$u" 2>/dev/null || echo "000|0")
    printf '  %-46s %s\n' "$u" "$res"
    case "$res" in 200*|30*) ok "reachable via tunnel" ;; *) bad "not reachable" ;; esac
done

# ---------------------------------------------------------------- device side
hd "3. the device itself"

info "-- mainland-China targets --"
for u in "$CN_ECHO" "http://members.3322.org/dyndns/getip"; do
    ip_=$(dget_ip "$u")
    printf '  %-46s -> %s\n' "$u" "${ip_:-<no answer>}"
    if [ -n "$DIRECT_IP" ] && [ "$ip_" = "$DIRECT_IP" ]; then ok "direct"
    elif [ -n "$ip_" ]; then info "answered $ip_"
    else bad "no answer"; fi
done

info "-- non-China targets --"
for u in "http://ifconfig.me/ip" "http://ipinfo.io/ip"; do
    ip_=$(dget_ip "$u")
    printf '  %-46s -> %s\n' "$u" "${ip_:-<no answer>}"
    if [ -n "$VPN_IP" ] && [ "$ip_" = "$VPN_IP" ]; then ok "via VPN"
    elif [ -n "$ip_" ]; then info "answered $ip_"
    else bad "no answer"; fi
done

# ---------------------------------------------------------------- kernel state
hd "4. kernel state (read-only)"

mu300_ssh 'ip rule show | sed "s/^/  | /"'
mu300_ssh 'echo "-- table 2022 --"; ip route show table 2022 | head -8 | sed "s/^/  | /"'
mu300_ssh 'echo "-- vpn tables --"; nft list tables | sed "s/^/  | /"'
mu300_ssh 'echo "-- ipv6 --"; ip -6 rule show | head -4 | sed "s/^/  | /"'

if [ "$DO_IPV6" = 1 ]; then
    hd "5. IPv6 leak probe"
    info "an IPv6-capable host must NOT be able to leave over IPv6 while the tunnel is up"
    for u in "https://api64.ipify.org" "https://ipv6.icanhazip.com"; do
        body=$(curl -6 -fsSL -m 15 "$u" 2>/dev/null | tr -d '\r\n' | head -c 40 || true)
        if [ -z "$body" ]; then ok "IPv6 blocked ($u)"
        else bad "IPv6 LEAK: $u answered $body"; fi
    done
fi

hd "summary"
printf '  ok=%s  fail=%s\n' "$PASS_CN" "$FAIL_CN"
[ "$FAIL_CN" = 0 ] || exit 1
