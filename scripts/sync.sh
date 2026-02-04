#!/bin/bash
set -u # 移除 -e，我们要手动处理错误
# set -o pipefail # 移除 pipefail，避免部分命令管道错误导致直接退出

CONFIG=$1

TOTAL=0
NOCHANGE=0
SUCCESS=0
FAILED=0

REPORT="📊 同步报告（UTC+8）\n"
TZ_TIME=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
REPORT+="🕒 时间：$TZ_TIME\n\n"

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed."
    exit 1
fi

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
  # 使用 token 克隆以通过鉴权
  git clone "https://$GH_PAT@github.com/$fork.git" repo
  cd repo || exit

  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  git remote add upstream "https://github.com/$upstream.git"
  git fetch upstream

  # 强制重置本地环境与远程 fork 一致
  git checkout "$branch"
  git reset --hard "origin/$branch"

  LOG_FILE="../sync_error.log"
  rm -f "$LOG_FILE"

  SYNC_STATUS="success"
  
  echo "Trying MERGE with strategy 'ours'..."

  # ⭐ 核心修改：直接使用 Merge，不再尝试 Rebase
  # -X ours: 遇到冲突时，保留刚才 clone 下来的（你自己的）版本
  # --allow-unrelated-histories: 防止因上游重置历史导致的报错
  # &> "$LOG_FILE": 将标准输出和错误输出都写入日志，防止日志为空
  if ! git merge -X ours "upstream/$branch" --no-edit --allow-unrelated-histories &> "$LOG_FILE"; then
      echo "Merge failed!"
      cat "$LOG_FILE" # 在 Action 终端打印错误以便调试
      SYNC_STATUS="fail"
  else
      echo "Merge success, pushing..."
      # ⭐ Push
      # 这里不需要 force，因为是 merge 操作，是新增 commit。
      # 但为了保险（防止之前的 rebase 导致历史分叉），保留 force-with-lease
      if ! git push --force-with-lease "https://$GH_PAT@github.com/$fork.git" "$branch" &>> "$LOG_FILE"; then
          echo "Push failed!"
          SYNC_STATUS="fail"
      fi
  fi

  cd ..
  rm -rf repo

  # ⭐ 单仓库通知
  if [ "$notify" = "true" ]; then
    if [ "$SYNC_STATUS" = "success" ]; then
      MESSAGE="✅ Sync Success
Repo: $fork
Branch: $branch
Upstream: $upstream
Commit: $UPSTREAM_SHA"
    else
      # 读取日志内容（只取最后20行，防止消息过长）
      ERROR_LOG=""
      if [ -f "$LOG_FILE" ]; then
        ERROR_LOG=$(tail -n 20 "$LOG_FILE")
      fi

      MESSAGE="❌ Sync Failed
Repo: $fork
Branch: $branch
Upstream: $upstream
Commit: $UPSTREAM_SHA

日志:
$ERROR_LOG"
    fi

    # URL Encode message roughly or rely on curl data processing
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
      -d chat_id="$TG_CHAT_ID" \
      -d text="$MESSAGE" >/dev/null
  fi

  # ⭐ 统计成功/失败
  if [ "$SYNC_STATUS" = "success" ]; then
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
