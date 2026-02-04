#!/bin/bash
set -e

CONFIG=$1

for row in $(jq -c '.[]' $CONFIG); do
  fork=$(echo $row | jq -r '.fork')
  upstream=$(echo $row | jq -r '.upstream')
  branch=$(echo $row | jq -r '.branch')
  notify=$(echo $row | jq -r '.notify')

  echo "=== Checking $fork ($branch) ==="

  # 获取 upstream 最新 commit SHA
  UPSTREAM_SHA=$(curl -s -H "Authorization: token $GH_PAT" \
    https://api.github.com/repos/$upstream/commits/$branch | jq -r '.sha')

  # 获取 fork 最新 commit SHA
  FORK_SHA=$(curl -s -H "Authorization: token $GH_PAT" \
    https://api.github.com/repos/$fork/commits/$branch | jq -r '.sha')

  echo "Upstream SHA: $UPSTREAM_SHA"
  echo "Fork SHA:     $FORK_SHA"

  # 如果相同，则跳过同步（不通知）
  if [ "$UPSTREAM_SHA" = "$FORK_SHA" ]; then
    echo "No update for $fork ($branch), skipping..."
    continue
  fi

  echo "Update detected for $fork ($branch), syncing..."

  # 克隆 fork 仓库
  git clone https://$GH_PAT@github.com/$fork.git repo
  cd repo

  git remote add upstream https://github.com/$upstream.git
  git fetch upstream
  git fetch origin

  git checkout -B $branch origin/$branch

  # 尝试合并
  if git merge upstream/$branch --no-edit; then
    MERGE_STATUS="success"
  else
    MERGE_STATUS="fail"
  fi

  # 如果合并成功 → 尝试 push
  if [ "$MERGE_STATUS" = "success" ]; then
    if git push https://$GH_PAT@github.com/$fork.git $branch; then
      PUSH_STATUS="success"
    else
      PUSH_STATUS="fail"
    fi
  else
    PUSH_STATUS="fail"
  fi

  cd ..
  rm -rf repo

  # Telegram 通知逻辑
  if [ "$notify" = "true" ]; then
    if [ "$MERGE_STATUS" = "success" ] && [ "$PUSH_STATUS" = "success" ]; then
      MESSAGE="✅ Sync Success\nRepo: $fork\nBranch: $branch\nUpstream: $upstream\nCommit: $UPSTREAM_SHA"
    else
      MESSAGE="❌ Sync Failed\nRepo: $fork\nBranch: $branch\nUpstream: $upstream\nCommit: $UPSTREAM_SHA"
    fi

    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
      -d chat_id="$TG_CHAT_ID" \
      -d text="$MESSAGE"
  fi

done
