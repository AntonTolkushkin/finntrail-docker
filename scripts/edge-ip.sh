#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

STATE_DIR=${EDGE_STATE_DIR:-/var/lib/finntrail-edge}
AUDIT_LOG=${EDGE_AUDIT_LOG:-/var/log/finntrail-edge/actions.log}
LOCK_FILE=${EDGE_IP_LOCK_FILE:-/run/lock/finntrail-edge-ip.lock}
REGISTRY="$STATE_DIR/blocked-ips.tsv"
PORTS=${EDGE_IP_PORTS:-80,443}
RULE_COMMENT=${EDGE_UFW_COMMENT:-finntrail-edge}
WORK_DIR=

cleanup_work_dir() {
    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

trap cleanup_work_dir EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<'EOF'
Usage:
  edge-ip ban IP [permanent|15m|2h|7d|4w]
  edge-ip unban IP
  edge-ip list
  edge-ip clear
  edge-ip restore
  edge-ip expire

Rules are managed by UFW and block only TCP ports 80 and 443.
SSH and other services are unaffected.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "run this command as root"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

require_active_ufw() {
    if ! LC_ALL=C "$UFW_BIN" status | grep -Fxq 'Status: active'; then
        die "UFW is not active; enable and verify UFW before managing blocks"
    fi
}

normalize_ip() {
    local value=$1

    NORMALIZED_IP=$(
        python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError as error:
    print(error, file=sys.stderr)
    raise SystemExit(1)

print(address.compressed)
PY
    ) || die "invalid IP address: $value"

    if [[ $NORMALIZED_IP == *:* ]]; then
        IP_FAMILY=6
    else
        IP_FAMILY=4
    fi
}

duration_to_seconds() {
    local value=$1

    case "$value" in
        permanent|perm|forever)
            DURATION_SECONDS=0
            DURATION_LABEL=permanent
            ;;
        *[smhdw])
            local number=${value%?}
            local unit=${value: -1}
            local multiplier

            [[ $number =~ ^[1-9][0-9]*$ ]] || die "invalid duration: $value"

            case "$unit" in
                s) multiplier=1 ;;
                m) multiplier=60 ;;
                h) multiplier=3600 ;;
                d) multiplier=86400 ;;
                w) multiplier=604800 ;;
            esac

            DURATION_SECONDS=$((number * multiplier))
            DURATION_LABEL=$value
            ;;
        *)
            die "duration must be permanent or NUMBER[s|m|h|d|w]: $value"
            ;;
    esac
}

ensure_layout() {
    install -d -o root -g root -m 0750 "$STATE_DIR"
    install -d -o root -g root -m 0750 "$(dirname -- "$AUDIT_LOG")"
    install -d -o root -g root -m 0755 "$(dirname -- "$LOCK_FILE")"

    if [[ ! -e $REGISTRY ]]; then
        install -o root -g root -m 0640 /dev/null "$REGISTRY"
    fi
    if [[ ! -e $AUDIT_LOG ]]; then
        install -o root -g root -m 0640 /dev/null "$AUDIT_LOG"
    fi
}

validate_registry() {
    local registry=$1
    local line=0 family address expires extra

    while IFS=$'\t' read -r family address expires extra || [[ -n ${family:-} ]]; do
        line=$((line + 1))
        [[ -z ${family:-} ]] && continue
        [[ -z ${extra:-} ]] || die "invalid blocklist record at line $line"
        [[ $family == 4 || $family == 6 ]] || \
            die "invalid address family at line $line: $family"
        [[ $expires =~ ^[0-9]+$ ]] || \
            die "invalid expiration at line $line: $expires"
        normalize_ip "$address"
        [[ $IP_FAMILY == "$family" && $NORMALIZED_IP == "$address" ]] || \
            die "non-normalized address at line $line: $address"
    done < "$registry"

    if ! awk -F '\t' 'NF && seen[$2]++ { exit 1 }' "$registry"; then
        die "blocklist contains duplicate addresses"
    fi
}

write_registry() {
    local candidate=$1 action=$2

    validate_registry "$candidate"
    install -o root -g root -m 0640 "$candidate" "$REGISTRY"
    printf '%s\tip\t%s\n' "$(date --iso-8601=seconds)" "$action" >> "$AUDIT_LOG"
}

ufw_add() {
    local address=$1

    "$UFW_BIN" prepend deny in \
        proto tcp \
        from "$address" \
        to any port "$PORTS" \
        comment "$RULE_COMMENT"
}

ufw_delete() {
    local address=$1

    "$UFW_BIN" --force delete deny in \
        proto tcp \
        from "$address" \
        to any port "$PORTS" \
        comment "$RULE_COMMENT"
}

ufw_remove() {
    local address=$1

    # UFW skips an exact duplicate. Adding first makes the following delete
    # idempotent when the registry and the current UFW state differ.
    ufw_add "$address" >/dev/null
    ufw_delete "$address" >/dev/null
}

remove_registry_address() {
    local input=$1 address=$2 output=$3

    awk -F '\t' -v address="$address" '$2 != address' "$input" > "$output"
}

expire_registry() {
    local input=$1 output=$2 now=$3
    local family address expires

    : > "$output"
    while IFS=$'\t' read -r family address expires || [[ -n ${family:-} ]]; do
        [[ -z ${family:-} ]] && continue

        if (( expires != 0 && expires <= now )); then
            ufw_remove "$address"
            printf '%s\tip\texpire address=%s\n' \
                "$(date --iso-8601=seconds)" "$address" >> "$AUDIT_LOG"
            continue
        fi

        printf '%s\t%s\t%s\n' "$family" "$address" "$expires" >> "$output"
    done < "$input"
}

list_blocks() {
    local now family address expires expiry

    now=$(date +%s)
    printf '%-7s %-42s %s\n' FAMILY ADDRESS EXPIRES

    while IFS=$'\t' read -r family address expires || [[ -n ${family:-} ]]; do
        [[ -z ${family:-} ]] && continue

        if (( expires == 0 )); then
            expiry=permanent
        elif (( expires <= now )); then
            expiry=expired
        else
            expiry=$(date --date="@$expires" --iso-8601=seconds)
        fi

        printf '%-7s %-42s %s\n' "IPv$family" "$address" "$expiry"
    done < "$REGISTRY"
}

require_root
for dependency in awk cmp date flock grep install mktemp python3 sort; do
    require_command "$dependency"
done

UFW_BIN=${EDGE_UFW_BIN:-$(command -v ufw || true)}
[[ -n $UFW_BIN && -x $UFW_BIN ]] || die "ufw executable was not found"

require_active_ufw
ensure_layout
exec 9>"$LOCK_FILE"
flock 9
validate_registry "$REGISTRY"

command_name=${1:-}
case "$command_name" in
    ban|block)
        [[ $# -eq 2 || $# -eq 3 ]] || { usage >&2; exit 2; }

        normalize_ip "$2"
        address=$NORMALIZED_IP
        family=$IP_FAMILY
        duration_to_seconds "${3:-permanent}"

        now=$(date +%s)
        if (( DURATION_SECONDS == 0 )); then
            expires=0
        else
            expires=$((now + DURATION_SECONDS))
        fi

        WORK_DIR=$(mktemp -d "$STATE_DIR/.ip-edit.XXXXXX")
        work_dir=$WORK_DIR
        expire_registry "$REGISTRY" "$work_dir/active.tsv" "$now"
        remove_registry_address \
            "$work_dir/active.tsv" "$address" "$work_dir/without-address.tsv"
        printf '%s\t%s\t%s\n' "$family" "$address" "$expires" \
            >> "$work_dir/without-address.tsv"
        LC_ALL=C sort -t $'\t' -k1,1n -k2,2 "$work_dir/without-address.tsv" \
            > "$work_dir/candidate.tsv"

        ufw_add "$address" >/dev/null
        write_registry \
            "$work_dir/candidate.tsv" \
            "ban address=$address duration=$DURATION_LABEL"
        echo "IP blocked by UFW on ports $PORTS: $address ($DURATION_LABEL)"
        ;;

    unban|unblock|delete|del|remove)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }

        normalize_ip "$2"
        address=$NORMALIZED_IP

        if ! awk -F '\t' -v address="$address" \
            '$2 == address { found=1 } END { exit !found }' "$REGISTRY"; then
            die "IP block was not found: $address"
        fi

        WORK_DIR=$(mktemp -d "$STATE_DIR/.ip-edit.XXXXXX")
        work_dir=$WORK_DIR
        remove_registry_address "$REGISTRY" "$address" "$work_dir/candidate.tsv"
        ufw_remove "$address"
        write_registry "$work_dir/candidate.tsv" "unban address=$address"
        echo "IP unblocked: $address"
        ;;

    list)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        list_blocks
        ;;

    clear)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        while IFS=$'\t' read -r family address expires || [[ -n ${family:-} ]]; do
            [[ -z ${family:-} ]] && continue
            ufw_remove "$address"
        done < "$REGISTRY"

        WORK_DIR=$(mktemp -d "$STATE_DIR/.ip-edit.XXXXXX")
        : > "$WORK_DIR/candidate.tsv"
        write_registry "$WORK_DIR/candidate.tsv" clear
        echo "All Finntrail UFW IP blocks were removed"
        ;;

    restore|apply)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        WORK_DIR=$(mktemp -d "$STATE_DIR/.ip-edit.XXXXXX")
        now=$(date +%s)
        expire_registry "$REGISTRY" "$WORK_DIR/candidate.tsv" "$now"

        while IFS=$'\t' read -r family address expires || [[ -n ${family:-} ]]; do
            [[ -z ${family:-} ]] && continue
            ufw_add "$address" >/dev/null
        done < "$WORK_DIR/candidate.tsv"

        write_registry "$WORK_DIR/candidate.tsv" restore
        echo "Finntrail UFW IP blocklist restored"
        ;;

    expire)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        WORK_DIR=$(mktemp -d "$STATE_DIR/.ip-edit.XXXXXX")
        now=$(date +%s)
        expire_registry "$REGISTRY" "$WORK_DIR/candidate.tsv" "$now"

        if ! cmp -s "$WORK_DIR/candidate.tsv" "$REGISTRY"; then
            install -o root -g root -m 0640 "$WORK_DIR/candidate.tsv" "$REGISTRY"
        fi
        ;;

    help|-h|--help)
        usage
        ;;

    *)
        usage >&2
        exit 2
        ;;
esac
