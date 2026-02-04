#!/bin/bash
set -euo pipefail

CONFIG=$1

for row in $(jq -c '.[]' "$CONFIG"); do
  fork=$(echo "$row" | jq -r '.fork')
  upstream=$(echo "$row" | jq -r '.upstream')
  branch=$(echo "$row" | jq -r '.branch')

  echo "=== Checking $fork ($branch) ==="

  UPSTREAM_SHA=$(curl -s -H "Authorization: token $GH_PAT" \
    "https://api.github.com/repos/$upstream/commits/$branch" | jq -r '.sha')

  FORK_SHA=$(curl -s -H "Authorization: token $GH_PAT" \
    "https://api.github.com/repos/$fork/commits/$branch" | jq -r '.sha')

  echo "Upstream SHA: $UPSTREAM_SHA"
  echo "Fork  SHA:    $FORK_SHA"

  if [ "$UPSTREAM_SHA" = "$FORK_SHA" ]; then
    echo "No update, skipping."
    continue
  fi

  echo "Update detected, cloning..."

  rm -rf repo
  git clone "https://$GH_PAT@github.com/$fork.git" repo
  cd repo

  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  git remote add upstream "https://github.com/$upstream.git"
  git fetch upstream
  git fetch origin

  git checkout -B "$branch" "origin/$branch"

  echo "=== TRYING REBASE ==="
  git rebase "upstream/$branch" || {
    echo "=== REBASE FAILED ==="
    exit 1
  }

  echo "=== TRYING PUSH ==="
  git push "https://$GH_PAT@github.com/$fork.git" "$branch" || {
    echo "=== PUSH FAILED ==="
    exit 1
  }

  cd ..
  rm -rf repo

done
