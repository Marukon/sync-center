#!/bin/bash
set -euo pipefail

CONFIG=$1

for row in $(jq -c '.[]' "$CONFIG"); do
  fork=$(echo "$row" | jq -r '.fork')
  upstream=$(echo "$row" | jq -r '.upstream')
  branch=$(echo "$row" | jq -r '.branch')
  notify=$(echo "$row" | jq -r '.notify')

  echo "=== Checking $fork ($branch) ==="

  # 获取 upstream 最新 commit SHA
  UPSTREAM_SHA=$(curl -s -H "Authorization: token $GH_PAT" \
    "https://api.github.com/repos/$upstream/commits/$branch" | jq -r '.sha')

  # 获取 fork 最新 commit SHA
  FORK_SHA=$(curl -s -H "Authorization: token $GH_PAT" \
    "https://api.github.com/repos/$fork/commits/$branch" | jq -r '.sha')

  echo "Upstream SHA: $UPSTREAM_SHA"
  echo "Fork  SHA:    $FORK_SHA"

  # 如果相同，则跳过同步（不通知）
  if [ "$UPSTREAM_SHA" = "$FORK_SHA" ]; then
    echo "No update for $fork ($branch), skipping..."
    continue
  fi

  echo "Update detected for $fork ($branch), syncing..."

  # 克隆 fork 仓库
  rm -rf repo
  git clone "https://$GH_PAT@github.com/$fork.git" repo
  cd repo

  # 配置 Git 身份
  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  git remote add upstream "https://github.com/$upstream.git"
  git fetch upstream
  git fetch origin

  git checkout -B "$branch" "origin/$branch"

  MERGE_STATUS="success"
  PUSH_STATUS="success"
  LOG_FILE="../sync_error.log"
  rm -f "$LOG_FILE"

  echo "Trying REBASE first (方案 A)..."

  # ⭐ 方案 A：rebase
  if git rebase "upstream/$branch" >> /dev/null 2>>"$LOG_FILE"; then
    echo "Rebase success."
  else
    echo "Rebase failed, falling back to MERGE -X ours (方案 B)..."
    MERGE_STATUS="fallback"

    # 取消 rebase 状态
    git rebase --abort >/dev/null 2>&1 || true

    # ⭐ 方案 B：merge -X ours（保留你的修改）
    if git merge -X ours "upstream/$branch" --no-edit >> /dev/null 2>>"$LOG_FILE"; then
      echo "Merge -X ours success."
    else
      echo "Merge -X ours failed."
      MERGE_STATUS="fail"
    fi
  fi

  # 如果合并成功 → push
  if [ "$MERGE_STATUS" != "fail" ]; then
    echo "Pushing to $fork:$branch ..."
    if ! git push "https://$GH_PAT@github.com/$fork.git" "$branch" >> /dev/null 2>>"$LOG_FILE"; then
      PUSH_STATUS="fail"
    fi
  else
    PUSH_STATUS="fail"
  fi

  cd ..
  rm -rf repo

  # Telegram 通知逻辑
  if [ "$notify" = "true" ]; then
    if [ "$MERGE_STATUS" != "fail" ] && [ "$PUSH_STATUS" = "success" ]; then
      MESSAGE="✅ Sync Success
Repo: $fork
Branch: $branch
Upstream: $upstream
Commit: $UPSTREAM_SHA"
    else
      ERROR_LOG=$(cat "$LOG_FILE")
      MESSAGE="❌ Sync Failed
Repo: $fork
Branch: $branch
Upstream: $upstream
Commit: $UPSTREAM_SHA

日志:
$ERROR_LOG"
    fi

    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
      -d chat_id="$TG_CHAT_ID" \
      -d text="$MESSAGE" >/dev/null
  fi

done
