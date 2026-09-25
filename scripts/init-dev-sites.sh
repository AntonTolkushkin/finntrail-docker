#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo ".env is missing. Run scripts/init-env.sh development first." >&2
    exit 1
fi

www_path=$(sed -n 's/^WWW_PATH=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r' | tr -d "'\"")
case "$www_path" in
    ""|/)
        echo "WWW_PATH is empty or unsafe." >&2
        exit 1
        ;;
    /*) site_root=$www_path ;;
    *) site_root="$ROOT_DIR/${www_path#./}" ;;
esac

primary="$site_root/dev/public_html"
mkdir -p "$primary/bitrix" "$primary/upload" "$primary/local"

ensure_shared_link() {
    test_site=$1
    shared_dir=$2
    target="../../dev/public_html/$shared_dir"
    link="$site_root/$test_site/public_html/$shared_dir"

    mkdir -p "$site_root/$test_site/public_html/local"
    if [ -L "$link" ]; then
        current=$(readlink "$link")
        if [ "$current" != "$target" ]; then
            echo "Unexpected symlink $link -> $current (expected $target)." >&2
            exit 1
        fi
        return
    fi
    if [ -e "$link" ]; then
        echo "$link already exists and is not a symlink; nothing was overwritten." >&2
        exit 1
    fi
    ln -s "$target" "$link"
}

for test_site in dev1 dev2; do
    ensure_shared_link "$test_site" bitrix
    ensure_shared_link "$test_site" upload
done

echo "Development site directories are ready under $site_root."
