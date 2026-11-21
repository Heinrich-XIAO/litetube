#!/bin/sh
# Print the version this run publishes.
#
#   tools/next-version.sh [version]
set -eu
cd "$(dirname "$0")/.."

if [ -n "${1:-}" ]; then
    printf '%s\n' "${1#v}"
    exit 0
fi

TAGS=$(git ls-remote --tags --refs origin 'v*' | awk -F/ '{print $NF}')
if [ -z "$TAGS" ]; then
    echo "0.0.1"
    exit 0
fi
python3 .github/next_version.py $TAGS
