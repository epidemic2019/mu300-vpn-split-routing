#!/bin/sh
# restore.sh — put a backup made by backup.sh back onto the device.
#
#   ./restore.sh --dir backups/f50-20260101-120000 --host 192.168.1.1 --verify
#   ./restore.sh --dir backups/f50-20260101-120000 --host 192.168.1.1 --dry-run
#   ./restore.sh --dir backups/f50-20260101-120000 --host 192.168.1.1 --yes --only etc/mu300
#
# --verify    compare the archive against the device and change nothing
# --dry-run   print the exact commands, change nothing
# --yes       skip the final confirmation prompt
# --only P    restrict to a path prefix, e.g. `etc/mu300` to restore just the VPN
#
# BEFORE OVERWRITING ANYTHING the current /etc/mu300 is saved on the device to
# /tmp/mu300-prerestore-<time>.tar.gz, so a mistaken restore is itself reversible.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib-ssh.sh
. "$HERE/lib-ssh.sh"

HOST=""; PORT=22; USER=root; PASS=""
DIR=""; ONLY=""; VERIFY=0; DRY=0; YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --host|-h)  HOST="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --user)     USER="$2"; shift 2 ;;
        --pass|-w)  PASS="$2"; shift 2 ;;
        --dir)      DIR="$2"; shift 2 ;;
        --only)     ONLY="$2"; shift 2 ;;
        --verify)   VERIFY=1; shift ;;
        --dry-run|-n) DRY=1; shift ;;
        --yes)      YES=1; shift ;;
        --help)     sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$HOST" ] || { echo "error: --host <device-ip> is required" >&2; exit 2; }
[ -n "$DIR" ]  || { echo "error: --dir <backup-dir> is required" >&2; exit 2; }
[ -f "$DIR/etc.tar.gz" ] || { echo "error: $DIR/etc.tar.gz not found" >&2; exit 1; }

ARCHIVE_SHA=$(sha256sum "$DIR/etc.tar.gz" | cut -d' ' -f1)
echo "archive : $DIR/etc.tar.gz"
echo "sha256  : $ARCHIVE_SHA"
echo "device  : $USER@$HOST:$PORT"
echo "scope   : ${ONLY:-(everything in the archive)}"
echo

mu300_ssh_init --host "$HOST" --port "$PORT" --user "$USER" ${PASS:+--pass "$PASS"}

if [ "$VERIFY" = 1 ]; then
    echo "== verify: comparing the archive with the device =="
    LIST=$(mktemp); trap 'rm -f "$LIST"' EXIT
    tar tzf "$DIR/etc.tar.gz" | grep -v '/$' | sort > "$LIST"
    echo "  archive holds $(wc -l < "$LIST") files"
    echo
    echo "  files that currently DIFFER on the device:"
    DIFFS=0
    while read -r f; do
        case "$f" in
            etc/*) ;;
            *) continue ;;
        esac
        local_sum=$(tar xzOf "$DIR/etc.tar.gz" "$f" 2>/dev/null | md5sum | cut -d' ' -f1)
        remote_sum=$(mu300_ssh "md5sum /$f 2>/dev/null | cut -d' ' -f1" || true)
        if [ -z "$remote_sum" ]; then
            printf '    MISSING  /%s\n' "$f"; DIFFS=$((DIFFS+1))
        elif [ "$local_sum" != "$remote_sum" ]; then
            printf '    CHANGED  /%s\n' "$f"; DIFFS=$((DIFFS+1))
        fi
    done < "$LIST"
    [ "$DIFFS" = 0 ] && echo "    (none — the device matches the archive)" || echo "    $DIFFS difference(s)"
    echo
    echo "nothing was modified."
    exit 0
fi

if [ "$DRY" = 1 ]; then
    echo "== dry run =="
    printf '  $ scp %s %s@%s:/tmp/restore.tar.gz\n' "$DIR/etc.tar.gz" "$USER" "$HOST"
    printf '  $ tar czf /tmp/mu300-prerestore-<time>.tar.gz -C / etc/mu300\n'
    if [ -n "$ONLY" ]; then
        printf '  $ tar xzf /tmp/restore.tar.gz -C / %s/*\n' "$ONLY"
    else
        printf '  $ tar xzf /tmp/restore.tar.gz -C /\n'
    fi
    printf '  $ /etc/init.d/mu300-vpn restart   # or: mu300-vpn off && mu300-vpn on\n'
    echo
    echo "nothing was modified."
    exit 0
fi

echo "about to write onto $HOST:"
if [ -n "$ONLY" ]; then
    echo "  only: $ONLY/*"
else
    echo "  the ENTIRE archive (every etc/ path inside it)"
fi
echo "  a pre-restore snapshot of /etc/mu300 will be saved to /tmp first"
if [ "$YES" != 1 ]; then
    printf 'type "yes" to continue: '
    read -r a
    [ "$a" = "yes" ] || { echo "cancelled"; exit 1; }
fi
echo

echo "== 1. upload =="
mu300_scp "$DIR/etc.tar.gz" /tmp/mu300-restore.tar.gz
echo "   $(mu300_ssh 'wc -c < /tmp/mu300-restore.tar.gz') bytes"

echo "== 2. verify the upload =="
REMOTE_SHA=$(mu300_ssh 'sha256sum /tmp/mu300-restore.tar.gz | cut -d" " -f1')
if [ "$REMOTE_SHA" = "$ARCHIVE_SHA" ]; then
    echo "   sha256 matches"
else
    echo "   sha256 MISMATCH (local $ARCHIVE_SHA, remote $REMOTE_SHA) — aborting" >&2
    exit 1
fi

echo "== 3. pre-restore snapshot =="
mu300_ssh 'S=/tmp/mu300-prerestore-$(date +%Y%m%d-%H%M%S).tar.gz; tar czf $S -C / etc/mu300 2>/dev/null; echo "   saved $S"'

echo "== 4. restore =="
if [ -n "$ONLY" ]; then
    mu300_ssh "tar xzf /tmp/mu300-restore.tar.gz -C / '$ONLY'/* 2>/dev/null || \
               tar xzf /tmp/mu300-restore.tar.gz -C / --wildcards '$ONLY/*'"
else
    mu300_ssh 'tar xzf /tmp/mu300-restore.tar.gz -C /'
fi

echo "== 5. restart the service =="
mu300_ssh '/etc/init.d/mu300-vpn restart 2>/dev/null || true; sleep 3; mu300-vpn status' || true

echo "== 6. clean up =="
mu300_ssh 'rm -f /tmp/mu300-restore.tar.gz; echo "   removed the upload"'

echo
echo "done. confirm with: $HERE/verify.sh --host $HOST"
