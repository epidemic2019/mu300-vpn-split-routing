#!/bin/sh
# fetch-cn-cidrs.sh — refresh the mainland-China IP range lists under data/.
#
# The bundled lists are a snapshot. Re-run this to pick up upstream changes;
# IP delegation for China drifts slowly, so monthly is plenty.
#
# Usage: ./fetch-cn-cidrs.sh [--check]
#   --check   download to a temp file and report whether the bundled copy is
#             already up to date, without modifying anything
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
DATA=$(cd "$HERE/.." && pwd)/data

URL4="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
URL6="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china6.txt"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

have() { command -v "$1" >/dev/null 2>&1; }
if have curl; then DL="curl -fsSL"; elif have wget; then DL="wget -qO-"; else
    echo "error: need curl or wget" >&2; exit 1
fi

fetch() {
    # $1 url  $2 dest
    $DL "$1" > "$2"
    [ -s "$2" ] || { echo "error: empty download from $1" >&2; exit 1; }
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for pair in "4:$URL4" "6:$URL6"; do
    v=${pair%%:*}; url=${pair#*:}
    target="$DATA/cn-ipv$v.txt"
    fetch "$url" "$TMP/new$v.txt"

    new_n=$(grep -c . "$TMP/new$v.txt" || true)
    if [ "$CHECK" = 1 ]; then
        if [ -f "$target" ] && cmp -s "$target" "$TMP/new$v.txt"; then
            echo "cn-ipv$v.txt: up to date ($new_n ranges)"
        else
            old_n=$([ -f "$target" ] && grep -c . "$target" || echo 0)
            echo "cn-ipv$v.txt: OUT OF DATE (bundled $old_n ranges, upstream $new_n)"
        fi
        continue
    fi

    # sanity: every line must parse as a CIDR of the right family
    if ! awk -v v="$v" '
        /^[^#]/ {
            n = split($0, p, "/")
            if (n != 2 || p[2] + 0 < 0 || p[2] + 0 > 128) { bad = 1; print "  bad line: " $0 > "/dev/stderr" }
            if (v == 4 && $0 ~ /:/) { bad = 1; print "  wrong family: " $0 > "/dev/stderr" }
            if (v == 6 && $0 !~ /:/) { bad = 1; print "  wrong family: " $0 > "/dev/stderr" }
        }
        END { exit bad }
    ' "$TMP/new$v.txt"; then
        echo "error: cn-ipv$v.txt failed validation, leaving the bundled copy untouched" >&2
        exit 1
    fi

    if [ -f "$target" ] && cmp -s "$target" "$TMP/new$v.txt"; then
        echo "cn-ipv$v.txt: already current ($new_n ranges)"
    else
        cp "$TMP/new$v.txt" "$target"
        echo "cn-ipv$v.txt: updated to $new_n ranges  sha256=$(sha256sum "$target" | cut -c1-16)"
    fi
done

[ "$CHECK" = 1 ] || echo
[ "$CHECK" = 1 ] || echo "remember to re-run scripts/gen-split-config.py and redeploy."
