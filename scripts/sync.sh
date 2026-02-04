#!/bin/bash
set -euo pipefail

CONFIG=$1

TOTAL=0
NOCHANGE=0
SUCCESS=0
FAILED=0

REPORT="📊 同步报告（UTC+8）\n"
TZ_TIME=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
REPORT+="🕒 时间：$TZ_TIME\n\n"

for row in $(jq -c '.[]' "$CONFIG"); do
  TOTAL=$((TOTAL + 1))

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

  if [ "$UPSTREAM_SHA" = "$FORK_SHA" ]; then
    echo "No update, skipping."
    NOCHANGE=$((NOCHANGE + 1))
    REPORT+="• $fork（$branch）：无变化\n"
    continue
  fi

  echo "Update detected, syncing..."

  rm -rf repo
  git clone "https://$GH_PAT@github.com/$fork.git" repo
  cd repo

  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  git remote add upstream "https://github.com/$upstream.git"
  git fetch upstream

  # ⭐ 强制更新 fork/main 最新状态（解决 non-fast-forward）
  git fetch origin --prune --tags

  git checkout "$branch"
  git reset --hard "origin/$branch"

  LOG_FILE="../sync_error.log"
  rm -f "$LOG_FILE"

  MERGE_STATUS="success"
  PUSH_STATUS="success"

  echo "Trying REBASE first..."

  # ⭐ 方案 A：rebase
  set +e
  git rebase "upstream/$branch" >> /dev/null 2>>"$LOG_FILE"
  REBASE_CODE=$?
  set -e

  if [ $REBASE_CODE -ne 0 ]; then
    echo "Rebase failed, fallback to merge -X ours..."
    git rebase --abort >/dev/null 2>&1 || true

    # ⭐ 方案 B：merge -X ours（保留你的修改）
    set +e
    git merge -X ours "upstream/$branch" --no-edit >> /dev/null 2>>"$LOG_FILE"
    MERGE_CODE=$?
    set -e

    if [ $MERGE_CODE -ne 0 ]; then
      MERGE_STATUS="fail"
    fi
  fi

  # ⭐ push（必须使用 --force-with-lease）
  if [ "$MERGE_STATUS" != "fail" ]; then
    set +e
    git push --force-with-lease "https://$GH_PAT@github.com/$fork.git" "$branch" >> /dev/null 2>>"$LOG_FILE"
    PUSH_CODE=$?
    set -e

    if [ $PUSH_CODE -ne 0 ]; then
      PUSH_STATUS="fail"
    fi
  else
    PUSH_STATUS="fail"
  fi

  cd ..
  rm -rf repo

  # ⭐ 单仓库通知
  if [ "$notify" = "true" ]; then
    if [ "$MERGE_STATUS" != "fail" ] && [ "$PUSH_STATUS" = "success" ]; then
      MESSAGE="✅ Sync Success
Repo: $fork
Branch: $branch
Upstream: $upstream
Commit: $UPSTREAM_SHA"
    else
      ERROR_LOG=""
      if [ -f "$LOG_FILE" ]; then
        ERROR_LOG=$(cat "$LOG_FILE")
      fi

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

  # ⭐ 统计成功/失败
  if [ "$MERGE_STATUS" != "fail" ] && [ "$PUSH_STATUS" = "success" ]; then
    SUCCESS=$((SUCCESS + 1))
    REPORT+="• $fork（$branch）：同步成功\n"
  else
    FAILED=$((FAILED + 1))
    REPORT+="• $fork（$branch）：同步失败\n"
  fi

done

# ⭐ 最终同步报告
REPORT+="\n📦 总仓库：$TOTAL\n"
REPORT+="🔹 无变化：$NOCHANGE\n"
REPORT+="🟢 成功：$SUCCESS\n"
REPORT+="🔴 失败：$FAILED\n"

curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
  -d chat_id="$TG_CHAT_ID" \
  -d text="$REPORT" >/dev/null
