#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TARGET_URL=git@github.com:AntonTolkushkin/finntrail-docker.git
MODE=check

usage() {
    cat <<'EOF'
Usage: ./scripts/publish-independent-repository.sh [options]

Options:
  --check                  Audit only (default).
  --publish-clean-history  Push the current tree as one new root commit.
  --publish-full-history   Push the current HEAD and its complete history.
  --target URL             Empty target repository URL.
  -h, --help               Show this help.

The publish modes never force-push. The GitHub target must be a new, empty
repository created with no README, .gitignore or license.
EOF
}

while (($#)); do
    case "$1" in
        --check) MODE=check; shift ;;
        --publish-clean-history) MODE=clean; shift ;;
        --publish-full-history) MODE=full; shift ;;
        --target) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; TARGET_URL=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

cd "$ROOT_DIR"
git rev-parse --is-inside-work-tree >/dev/null

status=$(git status --porcelain)
if [[ -n "$status" && "$MODE" != check ]]; then
    echo "Commit or stash all changes before publishing:" >&2
    printf '%s\n' "$status" >&2
    exit 1
fi

unstaged_deletions=$(git ls-files --deleted)
if [[ -n "$unstaged_deletions" ]]; then
    echo "Tracked deletions are not staged:" >&2
    printf '%s\n' "$unstaged_deletions" >&2
    echo "Run 'git add -A', review 'git diff --cached', then repeat the audit." >&2
    exit 1
fi

problem=0

echo "Checking tracked secrets, dumps and generated data..."
while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
        .env|.env.*|*/.env|*/.env.*)
            case "$path" in
                .env.example|.env.production.example|.env.development.example|*/.env.example) continue ;;
            esac
            ;;
        backups/.gitkeep|www/public_html/.gitkeep) continue ;;
        *.sql|*.sql.gz|*.tar.gz|*.zip|backups/*|www/public_html/*) ;;
        *) continue ;;
    esac
    echo "ERROR: generated/private path is tracked: $path" >&2
    problem=1
done < <(git ls-files)

if ! git ls-files --error-unmatch LICENSE >/dev/null 2>&1; then
    echo "ERROR: LICENSE must be retained with the inherited GPL components." >&2
    problem=1
fi

always_obsolete_paths=(
    docs/COMMIT_TO_FORK.md
    docker-compose.percona-migration.yml
    sources
)

runtime_candidates=(
    confs/php82
    confs/php83
    confs/php85
    confs/redis
    confs/sphinx
    confs/mariadb
)

echo "Checking known unused fork payload..."
for path in "${always_obsolete_paths[@]}"; do
    if git ls-files --error-unmatch "$path" >/dev/null 2>&1 || \
       git ls-files "$path/**" | grep -q .; then
        echo "ERROR: obsolete path is still tracked: $path" >&2
        problem=1
    fi
done

for path in "${runtime_candidates[@]}"; do
    if ! git ls-files --error-unmatch "$path" >/dev/null 2>&1 && \
       ! git ls-files "$path/**" | grep -q .; then
        continue
    fi

    if git grep -qF "$path" -- . ":!$path/**"; then
        echo "KEEP: runtime configuration is still referenced: $path"
    else
        echo "ERROR: unreferenced runtime configuration is still tracked: $path" >&2
        problem=1
    fi
done

legacy_url_log=$(mktemp /tmp/finntrail-repository-legacy-urls.XXXXXX)
trap 'rm -f -- "$legacy_url_log"' EXIT HUP INT TERM
if git grep -nE 'github\.com/AntonTolkushkin/env-docker(\.git)?' -- . \
    ':!docs/REPOSITORY-MOVE.md' >"$legacy_url_log" 2>/dev/null; then
    echo "ERROR: the old repository URL is still referenced:" >&2
    cat "$legacy_url_log" >&2
    problem=1
fi

if ((problem != 0)); then
    echo "Repository audit failed." >&2
    exit 1
fi

echo "Repository audit passed."

if [[ "$MODE" == check ]]; then
    exit 0
fi

case "$TARGET_URL" in
    *AntonTolkushkin/env-docker*)
        echo "Refusing to publish back to the old fork URL." >&2
        exit 1
        ;;
esac

echo "Checking that the target repository exists and is empty..."
if ! refs=$(git ls-remote --heads --tags "$TARGET_URL"); then
    echo "Cannot read target repository. Create it first and check SSH access." >&2
    exit 1
fi
if [[ -n "$refs" ]]; then
    echo "Target repository is not empty; nothing was pushed." >&2
    exit 1
fi

if [[ "$MODE" == full ]]; then
    git push "$TARGET_URL" HEAD:refs/heads/main
    echo "Complete history published to $TARGET_URL (main)."
    exit 0
fi

tree=$(git rev-parse 'HEAD^{tree}')
message='Initial Finntrail Docker environment'
root_commit=$(printf '%s\n' "$message" | git commit-tree "$tree")

git push "$TARGET_URL" "$root_commit":refs/heads/main

echo "Independent one-commit history published to $TARGET_URL (main)."
echo "Clone the new repository into a fresh directory; this checkout was not rewritten."
