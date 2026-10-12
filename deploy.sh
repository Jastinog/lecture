#!/usr/bin/env bash
# Deploys the backend on the server (lecture.intentio.pro): backs up the
# database, pulls main, syncs dependencies, migrates, collects static files,
# restarts gunicorn and checks that the API answers.
#
#   /root/Projects/lecture/deploy.sh
#
# The body is one function called on the last line, so bash has read the
# whole script before `git pull` replaces this file.
set -euo pipefail

SERVICE=lecture-gunicorn
BACKUPS=/root/backups
KEEP_BACKUPS=10
HEALTH_URL=http://127.0.0.1:8020/api/v1/groups/
HOST=lecture.intentio.pro

step() { printf '\n==> %s\n' "$*"; }

main() {
    cd "$(dirname "$(readlink -f "$0")")"
    local uv
    uv=$(command -v uv || echo /root/.local/bin/uv)

    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "Local changes in $(pwd); commit or discard them first." >&2
        git status --short >&2
        exit 1
    fi

    local before backup
    before=$(git rev-parse --short HEAD)
    backup="$BACKUPS/lecture-$(date +%Y%m%d-%H%M%S)-$before.sql.gz"
    trap 'echo; echo "Deploy failed. Database backup: $backup; previous commit: $before" >&2' ERR

    step "Backing up the database to $backup"
    mkdir -p "$BACKUPS"
    pg_dump "$(grep -E '^DATABASE_URL=' .env | cut -d= -f2-)" | gzip > "$backup"
    ls -1t "$BACKUPS"/lecture-*.sql.gz | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm --

    step "Pulling main"
    git pull --ff-only
    local after
    after=$(git rev-parse --short HEAD)
    if [ "$before" = "$after" ]; then
        echo "Already at $after; redeploying it."
    else
        git log --oneline "$before..$after"
    fi

    step "Syncing dependencies"
    "$uv" sync --frozen

    step "Migrating"
    "$uv" run python manage.py migrate --no-input

    step "Collecting static files"
    "$uv" run python manage.py collectstatic --no-input

    step "Restarting $SERVICE"
    systemctl restart "$SERVICE"
    for _ in $(seq 1 15); do
        if curl -fs -o /dev/null -H "Host: $HOST" "$HEALTH_URL"; then
            trap - ERR
            step "Deployed $after"
            return
        fi
        sleep 1
    done
    echo "The API didn't answer after the restart:" >&2
    systemctl status "$SERVICE" --no-pager -n 20 >&2 || true
    false
}

main "$@"
