#!/bin/sh
# Wait for this run's preflight to pass before publishing.
#
#   tools/await-preflight.sh
set -eu
cd "$(dirname "$0")/.."

: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is not set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
LIMIT=${PREFLIGHT_WAIT:-300}

started=$(date -u +%s)
while :; do
    conclusion=$(gh run view "$GITHUB_RUN_ID" --repo "$GITHUB_REPOSITORY" --json jobs \
        --jq '[.jobs[] | select(.name | startswith("preflight"))] | map(select(.status == "completed")) | .[0].conclusion // "pending"')
    case "$conclusion" in
        success)
            echo "preflight passed"
            exit 0
            ;;
        pending)
            ;;
        *)
            echo "preflight did not pass ($conclusion); not publishing" >&2
            exit 1
            ;;
    esac
    if [ $(( $(date -u +%s) - started )) -gt "$LIMIT" ]; then
        echo "preflight has not finished after ${LIMIT}s; not publishing" >&2
        exit 1
    fi
    sleep 3
done
