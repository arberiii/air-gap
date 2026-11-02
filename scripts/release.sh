#!/bin/bash
# Publishes the current main to the public repo as one snapshot commit, without main's history.
# Usage: scripts/release.sh "AirGap 1.1: CSV export and settings cleanup"
# Expects remotes "private" (full history) and "public" (one commit per release); the local
# "release" branch mirrors public/main.
set -euo pipefail
cd "$(dirname "$0")/.."
MESSAGE="${1:?Usage: scripts/release.sh \"AirGap X.Y: what changed\"}"
NAME="Arber Avdullahu"
EMAIL="8199285+arberiii@users.noreply.github.com"

[ "$(git branch --show-current)" = "main" ] || { echo "Run this from main." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first." >&2; exit 1; }
swift test -q

git fetch -q public
PARENT=()
if git rev-parse -q --verify refs/remotes/public/main >/dev/null; then
  [ "$(git rev-parse main^{tree})" != "$(git rev-parse public/main^{tree})" ] || { echo "Nothing new since the last release." >&2; exit 1; }
  PARENT=(-p public/main)
fi

COMMIT=$(GIT_AUTHOR_NAME="$NAME" GIT_AUTHOR_EMAIL="$EMAIL" GIT_COMMITTER_NAME="$NAME" GIT_COMMITTER_EMAIL="$EMAIL" \
  git commit-tree "main^{tree}" ${PARENT[@]+"${PARENT[@]}"} -m "$MESSAGE")
git branch -f release "$COMMIT"
git push public release:main
echo "Released $(git rev-parse --short "$COMMIT"): $MESSAGE"
