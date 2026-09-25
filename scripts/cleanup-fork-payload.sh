#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ ${1:-} != --apply || $# -ne 1 ]]; then
    cat >&2 <<'EOF'
Usage: ./scripts/cleanup-fork-payload.sh --apply

Remove confirmed unused upstream build payload from this checkout. Deleted
tracked files remain recoverable with Git until the cleanup commit is created.
EOF
    exit 2
fi

[[ -d "$ROOT_DIR/.git" ]] || {
    echo "Run this command inside the env-docker Git checkout." >&2
    exit 1
}
[[ -f "$ROOT_DIR/docker-compose.yml" && -f "$ROOT_DIR/confs/percona/zz-bitrix.cnf" ]] || {
    echo "This does not look like the migrated Finntrail Docker repository." >&2
    exit 1
}

paths=(
    confs/mariadb
    confs/php82
    confs/php83
    confs/php85
    confs/redis
    confs/sphinx
    docker-compose.percona-migration.yml
    docs/COMMIT_TO_FORK.md
    sources
)

echo "Removing confirmed unused fork payload:"
for relative_path in "${paths[@]}"; do
    target="$ROOT_DIR/$relative_path"
    case "$target" in
        "$ROOT_DIR"/*) ;;
        *) echo "Unsafe cleanup target: $target" >&2; exit 1 ;;
    esac

    if [[ -e "$target" || -L "$target" ]]; then
        printf '  %s\n' "$relative_path"
        rm -rf -- "$target"
    fi
done

echo
echo "Cleanup completed. Stage, audit and review the deletions:"
echo "  git status --short"
echo "  git add -A"
echo "  ./scripts/publish-independent-repository.sh --check"
echo "  git diff --cached --check"
