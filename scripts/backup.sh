#!/bin/sh
# backup.sh — take a complete, restorable snapshot of the device's configuration.
#
#   ./backup.sh --host 192.168.1.1
#   ./backup.sh --host 192.168.1.1 --only mu300      # just the VPN parts
#
# Everything is streamed over SSH straight to local files: the device is never
# asked to write anything, so a backup can be taken at any time without
# disturbing the running tunnel.
#
# WHAT YOU GET (in ./backups/<timestamp>/)
#   etc.tar.gz        the whole of /etc, verbatim
#   uci.txt           `uci export` for every package
#   netstate.txt      interfaces, routes, ip rules, nft, resolv.conf, cron
#   state.txt         per-file md5 of /etc  — lets you diff before/after later
#   vpn-status.txt    mu300-vpn status / settings / profile list
#   MANIFEST.md       inventory, sizes and hashes
#
# TREAT A BACKUP AS A SECRET: /etc contains your VLESS URI (and therefore the
# UUID), /etc/shadow, and the dropbear host keys.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=lib-ssh.sh
. "$HERE/lib-ssh.sh"

HOST=""; PORT=22; USER=root; PASS=""
ONLY="all"; OUTDIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --host|-h)  HOST="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --user)     USER="$2"; shift 2 ;;
        --pass|-w)  PASS="$2"; shift 2 ;;
        --only)     ONLY="$2"; shift 2 ;;
        --outdir)   OUTDIR="$2"; shift 2 ;;
        --help)     sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -n "$HOST" ] || { echo "error: --host <device-ip> is required" >&2; exit 2; }

case "$ONLY" in
    all)   SRCS="etc/mu300 etc/config etc/init.d etc/rc.d etc/dropbear etc/crontabs etc/hotplug.d" ;;
    mu300) SRCS="etc/mu300 etc/config" ;;
    *)     echo "error: --only must be 'all' or 'mu300'" >&2; exit 2 ;;
esac

STAMP=$(date +%Y%m%d-%H%M%S)
[ -n "$OUTDIR" ] || OUTDIR="$ROOT/backups/f50-$STAMP"
mkdir -p "$OUTDIR"

mu300_ssh_init --host "$HOST" --port "$PORT" --user "$USER" ${PASS:+--pass "$PASS"}

echo "device  : $MU300_USER@$MU300_HOST:$MU300_PORT"
echo "scope   : $ONLY"
echo "into    : $OUTDIR"
echo

echo "  -> etc.tar.gz"
# -C / so the archive restores with a plain `tar xzf ... -C /`
mu300_ssh "tar czf - -C / $SRCS 2>/dev/null" > "$OUTDIR/etc.tar.gz"
ENTRIES=$(tar tzf "$OUTDIR/etc.tar.gz" | wc -l)
echo "     $ENTRIES entries, $(wc -c < "$OUTDIR/etc.tar.gz") bytes"

echo "  -> uci.txt"
mu300_ssh 'uci export 2>/dev/null' > "$OUTDIR/uci.txt"

echo "  -> netstate.txt"
mu300_ssh 'sh -s' > "$OUTDIR/netstate.txt" <<'REMOTE'
echo "-- ip addr";       ip -br addr 2>/dev/null
echo "-- ip -6 addr";    ip -br -6 addr 2>/dev/null
echo "-- ip route";      ip route show 2>/dev/null
echo "-- ip -6 route";   ip -6 route show 2>/dev/null
echo "-- ip rule";       ip rule show 2>/dev/null
echo "-- ip -6 rule";    ip -6 rule show 2>/dev/null
echo "-- table 2022";    ip route show table 2022 2>/dev/null
echo "-- nft tables";    nft list tables 2>/dev/null
echo "-- resolv.conf";   cat /etc/resolv.conf 2>/dev/null
echo "-- crontabs";      for f in /etc/crontabs/*; do echo "[$f]"; cat "$f" 2>/dev/null; done
echo "-- processes";     ps w 2>/dev/null
echo "-- open ports";    netstat -ltn 2>/dev/null
echo "-- uname";         uname -a
REMOTE

echo "  -> state.txt"
mu300_ssh 'find /etc -type f 2>/dev/null | sort | xargs -r md5sum 2>/dev/null' > "$OUTDIR/state.txt"
echo "     $(wc -l < "$OUTDIR/state.txt") files hashed"

echo "  -> vpn-status.txt"
mu300_ssh 'sh -s' > "$OUTDIR/vpn-status.txt" <<'REMOTE'
echo "-- status";      mu300-vpn status 2>&1
echo "-- settings";    mu300-vpn settings get 2>&1
echo "-- profiles";    mu300-vpn profile list 2>&1
echo "-- enabled";     mu300-vpn enabled 2>&1
echo "-- vpn.conf";    cat /etc/mu300/vpn.conf 2>&1
echo "-- active";      cat /etc/mu300/vpn/active 2>&1
REMOTE

SHA_ETC=$(sha256sum "$OUTDIR/etc.tar.gz" | cut -d' ' -f1)

cat > "$OUTDIR/MANIFEST.md" <<EOF
# device configuration backup

| field | value |
|---|---|
| device | \`$MU300_USER@$MU300_HOST:$MU300_PORT\` |
| taken | $STAMP |
| scope | $ONLY |
| etc.tar.gz sha256 | \`$SHA_ETC\` |
| etc.tar.gz entries | $ENTRIES |
| files hashed | $(wc -l < "$OUTDIR/state.txt") |

## contents

| file | what it is |
|---|---|
| \`etc.tar.gz\` | the requested /etc subtree, verbatim (\`-C /\`) |
| \`uci.txt\` | \`uci export\` |
| \`netstate.txt\` | interfaces, routes, ip rules, nft, dns, cron, processes |
| \`state.txt\` | per-file md5 of /etc — diff this before/after a change |
| \`vpn-status.txt\` | mu300-vpn status / settings / profiles |

## restore

    ./restore.sh --dir "$OUTDIR" --host <device-ip> --verify
    ./restore.sh --dir "$OUTDIR" --host <device-ip> --only etc/mu300

## SECURITY

This archive contains your VLESS URI (UUID included), \`/etc/shadow\`, and the
dropbear host keys. Handle it like a password. It is listed in .gitignore and
must never be committed.
EOF

echo
echo "done."
echo "  etc.tar.gz sha256 = $SHA_ETC"
echo "  manifest          = $OUTDIR/MANIFEST.md"
echo
echo "verify a restore plan with:"
echo "  $HERE/restore.sh --dir $OUTDIR --host $HOST --verify"
