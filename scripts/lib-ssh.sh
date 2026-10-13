#!/bin/sh
# lib-ssh.sh — shared SSH plumbing for the other scripts. Source it, do not run it.
#
#   . "$(dirname "$0")/lib-ssh.sh"
#   mu300_ssh_init --host 192.168.1.1 --user root [--port 22] [--pass SECRET]
#   mu300_ssh 'some command'          # single command, output to stdout
#   mu300_ssh_script < local.sh       # pipe a whole script over stdin
#   mu300_scp  localfile /remote/path
#
# Credentials come from --pass, then $MU300_PASS, then an interactive prompt.
# Nothing is hardcoded, and the password never appears in ssh's argv: it is
# handed over through an askpass helper created mode 600 and removed on exit.
#
# Every script here treats the device as READ-ONLY unless it says otherwise.

MU300_HOST="${MU300_HOST:-}"
MU300_PORT="${MU300_PORT:-22}"
MU300_USER="${MU300_USER:-root}"
MU300_PASS="${MU300_PASS:-}"
MU300_ASKPASS=""
MU300_CTL=""

mu300_ssh_init() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --host) MU300_HOST="$2"; shift 2 ;;
            --port) MU300_PORT="$2"; shift 2 ;;
            --user) MU300_USER="$2"; shift 2 ;;
            --pass) MU300_PASS="$2"; shift 2 ;;
            *) echo "mu300_ssh_init: unknown option: $1" >&2; return 2 ;;
        esac
    done

    [ -n "$MU300_HOST" ] || { echo "error: no device host given (--host)" >&2; return 2; }

    if [ -z "$MU300_PASS" ]; then
        if [ -t 0 ]; then
            printf 'password for %s@%s: ' "$MU300_USER" "$MU300_HOST" >&2
            stty -echo 2>/dev/null || true
            read -r MU300_PASS
            stty echo 2>/dev/null || true
            printf '\n' >&2
        else
            echo "error: no password. Use --pass, export MU300_PASS, or run interactively." >&2
            return 2
        fi
    fi

    MU300_ASKPASS=$(mktemp)
    chmod 700 "$MU300_ASKPASS"
    {
        printf '#!/bin/sh\n'
        printf "printf '%%s\\\\n' '%s'\n" "$(printf '%s' "$MU300_PASS" | sed "s/'/'\\\\''/g")"
    } > "$MU300_ASKPASS"

    MU300_CTL="/tmp/mu300-ssh-%r@%h:%p"
    SSH_ASKPASS="$MU300_ASKPASS"
    SSH_ASKPASS_REQUIRE=force
    DISPLAY="${DISPLAY:-:0}"
    export SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY

    trap 'mu300_ssh_cleanup' EXIT INT TERM HUP
}

mu300_ssh_cleanup() {
    [ -n "$MU300_ASKPASS" ] && rm -f "$MU300_ASKPASS"
    MU300_ASKPASS=""
}

_mu300_ssh_opts() {
    printf '%s\n' \
        -F /dev/null \
        -p "$MU300_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o GlobalKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 \
        -o LogLevel=ERROR \
        -o ControlMaster=auto \
        -o ControlPath="$MU300_CTL" \
        -o ControlPersist=300
}

mu300_ssh() {
    # shellcheck disable=SC2046
    setsid -w ssh $(_mu300_ssh_opts) "$MU300_USER@$MU300_HOST" "$@"
}

mu300_ssh_script() {
    # shellcheck disable=SC2046
    setsid -w ssh $(_mu300_ssh_opts) "$MU300_USER@$MU300_HOST" 'sh -s'
}

mu300_scp() {
    setsid -w scp -F /dev/null -P "$MU300_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o GlobalKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o ControlPath="$MU300_CTL" \
        -o LogLevel=ERROR \
        "$1" "$MU300_USER@$MU300_HOST:$2"
}
