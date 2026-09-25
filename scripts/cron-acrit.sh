#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CRONTAB_FILE="$ROOT_DIR/confs/cron/crontabs/root"
ACRIT_COMMAND=/opt/project-cron/jobs/acrit-export

usage() {
    cat <<'EOF'
Usage:
  scripts/cron-acrit.sh add PROFILE_ID 'MIN HOUR DAY MONTH WEEKDAY'
  scripts/cron-acrit.sh remove PROFILE_ID
  scripts/cron-acrit.sh list

Examples:
  scripts/cron-acrit.sh add 1 '7 * * * *'
  scripts/cron-acrit.sh add 2 '*/30 * * * *'
  scripts/cron-acrit.sh add 3 '25 2 * * *'
  scripts/cron-acrit.sh remove 2
EOF
}

validate_profile_id() {
    case "$1" in
        ''|*[!0-9]*)
            echo "PROFILE_ID must be a positive integer." >&2
            exit 64
            ;;
    esac

    if [ "$1" -lt 1 ]; then
        echo "PROFILE_ID must be greater than zero." >&2
        exit 64
    fi
}

write_without_profile() {
    profile_id=$1
    output_file=$2

    awk \
        -v command="$ACRIT_COMMAND" \
        -v profile_id="$profile_id" \
        '!(NF >= 7 && $6 == command && $7 == profile_id) { print }' \
        "$CRONTAB_FILE" >"$output_file"
}

if [ ! -f "$CRONTAB_FILE" ]; then
    echo "Crontab file was not found: $CRONTAB_FILE" >&2
    exit 1
fi

action=${1:-}

case "$action" in
    add)
        profile_id=${2:-}
        schedule=${3:-}
        validate_profile_id "$profile_id"

        set -f
        old_ifs=$IFS
        IFS=' '
        set -- $schedule
        IFS=$old_ifs
        set +f

        if [ "$#" -ne 5 ]; then
            echo "Schedule must contain exactly five cron fields." >&2
            usage >&2
            exit 64
        fi

        for field in "$@"; do
            case "$field" in
                ''|*[!0-9*/,-]*)
                    echo "Unsupported cron field: $field" >&2
                    exit 64
                    ;;
            esac
        done

        minute=$1
        hour=$2
        day=$3
        month=$4
        weekday=$5

        temp_file=$(mktemp "$CRONTAB_FILE.XXXXXX")
        trap 'rm -f "$temp_file"' EXIT HUP INT TERM

        write_without_profile "$profile_id" "$temp_file"
        printf '%s %s %s %s %s %s %s\n' \
            "$minute" "$hour" "$day" "$month" "$weekday" \
            "$ACRIT_COMMAND" "$profile_id" \
            >>"$temp_file"

        chmod 0644 "$temp_file"
        mv "$temp_file" "$CRONTAB_FILE"
        trap - EXIT HUP INT TERM

        echo "Acrit profile $profile_id schedule saved: $schedule"
        ;;

    remove)
        profile_id=${2:-}
        validate_profile_id "$profile_id"

        temp_file=$(mktemp "$CRONTAB_FILE.XXXXXX")
        trap 'rm -f "$temp_file"' EXIT HUP INT TERM

        write_without_profile "$profile_id" "$temp_file"
        chmod 0644 "$temp_file"
        mv "$temp_file" "$CRONTAB_FILE"
        trap - EXIT HUP INT TERM

        echo "Acrit profile $profile_id schedule removed."
        ;;

    list)
        awk \
            -v command="$ACRIT_COMMAND" \
            'NF >= 7 && $6 == command { print }' \
            "$CRONTAB_FILE"
        ;;

    *)
        usage >&2
        exit 64
        ;;
esac
