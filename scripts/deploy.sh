#!/bin/sh
# deploy.sh — install a split-routing profile on a ZTE F50 / MU300 running mu300-vpn.
#
#   ./deploy.sh --host 192.168.1.1                        # sing-box (recommended)
#   ./deploy.sh --host 192.168.1.1 --lan-cidrs 192.168.1.0/24
#   ./deploy.sh --host 192.168.1.1 --config out/split-cn.singbox.json
#   ./deploy.sh --host 192.168.1.1 --dry-run              # print the plan only
#
# Password: --pass, or $MU300_PASS, or you will be prompted.
#
# What it does, in order:
#   0. safety snapshot of /etc/mu300 into /tmp on the device
#   1. `mu300-vpn off`                     — never swap a profile under a live tunnel
#   2. `settings set LAN_CIDRS <lan>`      — LAN traffic bypasses the tunnel entirely
#   3. upload the config, `profile import`, `profile use`
#   4. `mu300-vpn check <profile>`         — the device's own whitelist rebuild + engine check
#   5. `mu300-vpn on`
#   6. status + kernel-state dump
#
# WHY SING-BOX IS THE DEFAULT
#   `pick_engines` contains:
#       if [ "$ENGINE" = xray ] && [ "$KILL_SWITCH" = 1 ] && [ -x "$BIN" ]; then ENGINE=sing-box; fi
#   With the shipped defaults (KILL_SWITCH=1) and sing-box installed, a share-link
#   profile is ALWAYS handed to sing-box. An Xray config would sit on disk unused.
#   Choosing --engine xray therefore also requires KILL_SWITCH=0, which gives up
#   the fail-closed guarantee. That is why sing-box is the default and Xray is
#   opt-in behind a confirmation.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=lib-ssh.sh
. "$HERE/lib-ssh.sh"

HOST=""; PORT=22; USER=root; PASS=""
CONFIG=""; LAN=""; ENGINE=singbox; PROFILE=""; DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --host|-h)    HOST="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --user)       USER="$2"; shift 2 ;;
        --pass|-w)    PASS="$2"; shift 2 ;;
        --config)     CONFIG="$2"; shift 2 ;;
        --lan-cidrs|--lan) LAN="$2"; shift 2 ;;
        --engine|-e)  ENGINE="$2"; shift 2 ;;
        --profile)    PROFILE="$2"; shift 2 ;;
        --dry-run|-n) DRY=1; shift ;;
        --help)       sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$HOST" ] || { echo "error: --host <device-ip> is required" >&2; exit 2; }
[ -n "$CONFIG" ] || CONFIG="$ROOT/out/split-cn.$([ "$ENGINE" = xray ] && echo xray || echo singbox).json"
[ -f "$CONFIG" ] || { echo "error: config not found: $CONFIG
run scripts/gen-split-config.py first" >&2; exit 1; }
[ -n "$PROFILE" ] || PROFILE="$([ "$ENGINE" = xray ] && echo split-cn-xray || echo split-cn)"

mu300_ssh_init --host "$HOST" --port "$PORT" --user "$USER" --pass "$PASS" 2>/dev/null || {
    # init may legitimately need the prompt, so retry with a visible stderr
    mu300_ssh_init --host "$HOST" --port "$PORT" --user "$USER" ${PASS:+--pass "$PASS"}
}

echo "device    : $MU300_USER@$MU300_HOST:$MU300_PORT"
echo "config    : ${CONFIG#"$ROOT"/}  ($(wc -c < "$CONFIG") bytes)"
echo "profile   : $PROFILE"
echo "engine    : $ENGINE"
echo "LAN       : ${LAN:-(leave the device setting untouched)}"
echo

run() {
    printf '  $ %s\n' "$*"
    [ "$DRY" = 1 ] || mu300_ssh "$@"
}

echo "== 0. safety snapshot on the device =="
run "S=/tmp/mu300-predeploy-\$(date +%Y%m%d-%H%M%S).tar.gz; tar czf \$S -C / etc/mu300 etc/config && echo saved \$S"
echo "   (roll back with: tar xzf <snapshot> -C /)"
echo

echo "== 1. tunnel off =="
run "mu300-vpn off || true"
echo

if [ -n "$LAN" ]; then
    echo "== 2. LAN subnet =="
    echo "   sing-box : TUN route_exclude_address = [$LAN]  -> LAN never enters the tunnel"
    echo "   xray     : ip rule pref 9001 to <LAN> lookup main"
    run "mu300-vpn settings set LAN_CIDRS '$LAN'"
    echo
else
    echo "== 2. LAN subnet: skipped (--lan-cidrs not given) =="
    echo "   NOTE: the config was generated with its own LAN value. If it does not"
    echo "   match \`mu300-vpn settings get LAN_CIDRS\`, LAN clients may be misrouted."
    echo
fi

echo "== 3. upload + import =="
if [ "$DRY" = 1 ]; then
    printf '  $ scp %s %s@%s:/tmp/mu300-split.json\n' "${CONFIG#"$ROOT"/}" "$USER" "$HOST"
    printf '  $ mu300-vpn profile import /tmp/mu300-split.json %s && mu300-vpn profile use %s\n' "$PROFILE" "$PROFILE"
else
    mu300_scp "$CONFIG" /tmp/mu300-split.json
    echo "  uploaded $(mu300_ssh 'wc -c < /tmp/mu300-split.json') bytes"
    mu300_ssh "mu300-vpn profile import /tmp/mu300-split.json '$PROFILE' && mu300-vpn profile use '$PROFILE'"
fi
run "mu300-vpn profile list"
echo

echo "== 4. device-side validation =="
echo "   (rebuilds through the key whitelist and runs the engine's own check)"
run "mu300-vpn check '$PROFILE'"
echo

if [ "$ENGINE" = "xray" ]; then
    cat <<'WARN'
== 5. Xray requires KILL_SWITCH=0 ==========================================
  Turning the kill switch off means:
    * when the tunnel drops, traffic falls through to the carrier in the clear
    * traffic from your LAN clients is briefly exposed at the uplink
  With KILL_SWITCH=1 (the default) the engine is forced to sing-box anyway.
  Prefer the sing-box config unless you specifically need Xray.
===========================================================================
WARN
    if [ "$DRY" = 1 ]; then
        printf '  $ mu300-vpn settings set KILL_SWITCH 0\n'
    else
        printf '  type "yes" to continue: '
        read -r a
        [ "$a" = "yes" ] || { echo "cancelled"; exit 1; }
        mu300_ssh "mu300-vpn settings set KILL_SWITCH 0"
    fi
    echo
fi

echo "== 6. tunnel on =="
run "mu300-vpn on"
run "mu300-vpn status"
echo

echo "== 7. expected kernel state =="
cat <<'EOF'
  ip rule show                     sing-box: 5198 9000 9001 9002 9003 9010
                                   xray    : 9000(mark 0x2d0) 9001(LAN) 9002(server) 9010
  ip route show table 2022         default route into sbtun / xtun
  ip link show sbtun               sing-box TUN (or xtun for xray)
  nft list table inet mu300_vpn    kill switch: accepts only mark 0x2d0
  ip -6 rule show                  9000: from all unreachable  (IPv6 closed)
  ps w | grep -E 'sing-box|xray'

Now run scripts/verify.sh --host <device-ip> from a LAN client to confirm the
split actually behaves as intended.
EOF
