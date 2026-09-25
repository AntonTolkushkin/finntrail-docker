#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

STATE_DIR=${EDGE_STATE_DIR:-/var/lib/finntrail-edge}
RULES_DIR=${EDGE_NGINX_RULES_DIR:-/etc/nginx/finntrail-rules}
AUDIT_LOG=${EDGE_AUDIT_LOG:-/var/log/finntrail-edge/actions.log}
LOCK_FILE=${EDGE_REDIRECT_LOCK_FILE:-/run/lock/finntrail-edge-redirect.lock}
CANONICAL_ORIGIN=${EDGE_CANONICAL_ORIGIN:-https://finntrail.ru}

REGISTRY="$STATE_DIR/redirects.tsv"
MAP_301="$RULES_DIR/redirects-301.map"
MAP_302="$RULES_DIR/redirects-302.map"
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
  edge-redirect add 301|302 /source/path /target/path
  edge-redirect add 301|302 /source/path https://example.com/target
  edge-redirect delete /source/path
  edge-redirect list
  edge-redirect apply

Matching uses the normalized Nginx $uri and ignores the query string.
Relative targets are expanded using EDGE_CANONICAL_ORIGIN.
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

validate_source() {
    local value=$1

    [[ $value == /* ]] || die "source must start with /: $value"
    [[ $value != *'?'* && $value != *'#'* ]] || \
        die "source must contain only a path, without query or fragment: $value"

    case "$value" in
        *$'\n'*|*$'\r'*|*$'\t'*|*' '*|*'"'*|*'\\'*|*';'*|*'$'*)
            die "source contains unsupported characters: $value"
            ;;
    esac
}

normalize_target() {
    local value=$1

    case "$value" in
        /*)
            NORMALIZED_TARGET="${CANONICAL_ORIGIN%/}$value"
            ;;
        http://*|https://*)
            NORMALIZED_TARGET=$value
            ;;
        *)
            die "target must start with /, http:// or https://: $value"
            ;;
    esac

    case "$NORMALIZED_TARGET" in
        *$'\n'*|*$'\r'*|*$'\t'*|*' '*|*'"'*|*'\\'*|*';'*|*'$'*)
            die "target contains unsupported characters: $NORMALIZED_TARGET"
            ;;
    esac
}

ensure_layout() {
    install -d -o root -g root -m 0750 "$STATE_DIR"
    install -d -o root -g root -m 0755 "$RULES_DIR"
    install -d -o root -g root -m 0750 "$(dirname -- "$AUDIT_LOG")"
    install -d -o root -g root -m 0755 "$(dirname -- "$LOCK_FILE")"

    if [[ ! -e $REGISTRY ]]; then
        install -o root -g root -m 0640 /dev/null "$REGISTRY"
    fi
    if [[ ! -e $MAP_301 ]]; then
        install -o root -g root -m 0644 /dev/null "$MAP_301"
    fi
    if [[ ! -e $MAP_302 ]]; then
        install -o root -g root -m 0644 /dev/null "$MAP_302"
    fi
    if [[ ! -e $AUDIT_LOG ]]; then
        install -o root -g root -m 0640 /dev/null "$AUDIT_LOG"
    fi
}

validate_registry() {
    local registry=$1
    local line=0 status source target extra

    while IFS=$'\t' read -r status source target extra || [[ -n ${status:-} ]]; do
        line=$((line + 1))
        [[ -z ${status:-} ]] && continue
        [[ -z ${extra:-} ]] || die "invalid registry record at line $line"
        [[ $status == 301 || $status == 302 ]] || \
            die "invalid redirect status at line $line: $status"
        validate_source "$source"
        normalize_target "$target"
        [[ $NORMALIZED_TARGET == "$target" ]] || \
            die "registry target must already be absolute at line $line"
    done < "$registry"

    if ! awk -F '\t' '
        NF && seen[$2]++ { exit 1 }
    ' "$registry"; then
        die "redirect registry contains duplicate source paths"
    fi
}

generate_maps() {
    local registry=$1 output_301=$2 output_302=$3
    local status source target

    printf '%s\n' '# Managed by edge-redirect. Do not edit directly.' > "$output_301"
    printf '%s\n' '# Managed by edge-redirect. Do not edit directly.' > "$output_302"

    while IFS=$'\t' read -r status source target || [[ -n ${status:-} ]]; do
        [[ -z ${status:-} ]] && continue
        if [[ $status == 301 ]]; then
            printf '"%s" "%s";\n' "$source" "$target" >> "$output_301"
        else
            printf '"%s" "%s";\n' "$source" "$target" >> "$output_302"
        fi
    done < "$registry"
}

restore_files() {
    local work_dir=$1

    install -o root -g root -m 0640 "$work_dir/registry.old" "$REGISTRY"
    install -o root -g root -m 0644 "$work_dir/map-301.old" "$MAP_301"
    install -o root -g root -m 0644 "$work_dir/map-302.old" "$MAP_302"
}

publish_registry() {
    local candidate=$1 action=$2 work_dir=$3

    validate_registry "$candidate"

    cp -a -- "$REGISTRY" "$work_dir/registry.old"
    cp -a -- "$MAP_301" "$work_dir/map-301.old"
    cp -a -- "$MAP_302" "$work_dir/map-302.old"

    generate_maps "$candidate" "$work_dir/map-301.new" "$work_dir/map-302.new"

    install -o root -g root -m 0640 "$candidate" "$REGISTRY"
    install -o root -g root -m 0644 "$work_dir/map-301.new" "$MAP_301"
    install -o root -g root -m 0644 "$work_dir/map-302.new" "$MAP_302"

    if ! "$NGINX_BIN" -t; then
        restore_files "$work_dir"
        die "nginx configuration test failed; redirect files were rolled back"
    fi

    if ! "$NGINX_BIN" -s reload; then
        restore_files "$work_dir"
        "$NGINX_BIN" -t >/dev/null 2>&1 && \
            "$NGINX_BIN" -s reload >/dev/null 2>&1 || true
        die "nginx reload failed; redirect files were rolled back"
    fi

    printf '%s\tredirect\t%s\n' "$(date --iso-8601=seconds)" "$action" >> "$AUDIT_LOG"
}

list_redirects() {
    local status source target

    printf '%-6s %-45s %s\n' STATUS SOURCE TARGET
    while IFS=$'\t' read -r status source target || [[ -n ${status:-} ]]; do
        [[ -z ${status:-} ]] && continue
        printf '%-6s %-45s %s\n' "$status" "$source" "$target"
    done < "$REGISTRY"
}

require_root
for dependency in awk cmp flock install mktemp sort; do
    require_command "$dependency"
done

NGINX_BIN=${EDGE_NGINX_BIN:-$(command -v nginx || true)}
[[ -n $NGINX_BIN && -x $NGINX_BIN ]] || die "nginx executable was not found"

ensure_layout
exec 9>"$LOCK_FILE"
flock 9

command_name=${1:-}
case "$command_name" in
    add)
        [[ $# -eq 4 ]] || { usage >&2; exit 2; }
        status=$2
        source=$3
        target=$4

        [[ $status == 301 || $status == 302 ]] || die "status must be 301 or 302"
        validate_source "$source"
        normalize_target "$target"
        target=$NORMALIZED_TARGET

        WORK_DIR=$(mktemp -d "$STATE_DIR/.redirect-edit.XXXXXX")
        work_dir=$WORK_DIR
        awk -F '\t' -v source="$source" '$2 != source' "$REGISTRY" \
            > "$work_dir/without-source.tsv"
        printf '%s\t%s\t%s\n' "$status" "$source" "$target" \
            >> "$work_dir/without-source.tsv"
        LC_ALL=C sort -t $'\t' -k2,2 "$work_dir/without-source.tsv" \
            > "$work_dir/candidate.tsv"

        if cmp -s "$work_dir/candidate.tsv" "$REGISTRY"; then
            echo "Redirect is already configured: $source"
            exit 0
        fi

        publish_registry \
            "$work_dir/candidate.tsv" \
            "add status=$status source=$source target=$target" \
            "$work_dir"
        echo "Redirect added: $source -> $target ($status)"
        ;;

    delete|del|remove)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        source=$2
        validate_source "$source"

        if ! awk -F '\t' -v source="$source" '$2 == source { found=1 } END { exit !found }' \
            "$REGISTRY"; then
            die "redirect was not found: $source"
        fi

        WORK_DIR=$(mktemp -d "$STATE_DIR/.redirect-edit.XXXXXX")
        work_dir=$WORK_DIR
        awk -F '\t' -v source="$source" '$2 != source' "$REGISTRY" \
            > "$work_dir/candidate.tsv"
        publish_registry \
            "$work_dir/candidate.tsv" \
            "delete source=$source" \
            "$work_dir"
        echo "Redirect deleted: $source"
        ;;

    list)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        validate_registry "$REGISTRY"
        list_redirects
        ;;

    apply)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        WORK_DIR=$(mktemp -d "$STATE_DIR/.redirect-edit.XXXXXX")
        work_dir=$WORK_DIR
        cp -- "$REGISTRY" "$work_dir/candidate.tsv"
        publish_registry "$work_dir/candidate.tsv" apply "$work_dir"
        echo "Redirect maps regenerated and Nginx reloaded"
        ;;

    help|-h|--help)
        usage
        ;;

    *)
        usage >&2
        exit 2
        ;;
esac
