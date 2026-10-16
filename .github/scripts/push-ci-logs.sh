#!/usr/bin/env bash
# Pushes CI diagnostics (build/test logs, screenshot) to the ci-logs branch so they can be read without
# access to the Actions log API.   push-ci-logs.sh <report-dir> <token>
set +e
REPORT="$1"; TOKEN="$2"
[ -d "$REPORT" ] || exit 0
D=$(mktemp -d)
cd "$D" && git init -q && git checkout -q -b ci-logs
git config user.name ci && git config user.email ci@localhost
git remote add origin "https://x-access-token:${TOKEN}@github.com/${GITHUB_REPOSITORY}"
for attempt in 1 2 3 4 5 6 7 8; do
  # start from the current tip every time, so parallel jobs never drop each other's logs
  git fetch -q --depth 1 origin ci-logs && git reset -q --hard origin/ci-logs
  cp -R "$REPORT"/. .
  git add -A && git commit -qm "logs $(ls "$REPORT" | tr '\n' ' ')" && git push -q origin HEAD:ci-logs && exit 0
  sleep $((attempt * 4))
done
exit 0
