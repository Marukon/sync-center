#!/bin/bash
set -u   # 不能用 set -e，否则脚本中途退出导致报告不发送

CONFIG=$1

TOTAL=0
NOCHANGE=0
SUCCESS=0
FAILED=0

SUCCESS_LIST=""

# 北京时间
TZ_TIME=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')

REPORT="📊 *上游同步报告（北京时间）*\n"
REPORT+="🕒 $TZ_TIME\n\n"

for row in $(jq -c '.[]' "$CONFIG"); do
  TOTAL=$((TOTAL + 1))

  fork=$(echo "$row" | jq -r '.fork')
  upstream=$(echo "$row" | jq -r '.upstream')
  branch=$(echo "$row" | jq -r '.branch')
  notify=$(echo "$row" | jq -r '.notify')

  echo "=== Checking $fork ($branch) ==="

  # 获取 upstream 最新 commit
  UPSTREAM_SHA=$(curl -s -H "Authorization: token $GH_PAT" \
    "https://api.github.com/repos/$upstream/branches/$branch" | jq -r '.commit.sha')

  # 获取 fork 最新 commit
  FORK_SHA=$(curl -s -H "Authorization: token $GH_PAT" \
    "https://api.github.com/repos/$fork/branches/$branch" | jq -r '.commit.sha')

  # ⭐ 判断 upstream 是否领先（而不是 SHA 是否不同）
  # 如果 upstream 有新 commit → upstream ahead > 0
  TMP_DIR=$(mktemp -d)
  cd "$TMP_DIR"

  git init -q
  git remote add upstream "https://github.com/$upstream.git"
  git remote add fork "https://github.com/$fork.git"
  git fetch upstream -q
  git fetch fork -q

  AHEAD=$(git rev-list --left-right --count fork/$branch...upstream/$branch | awk '{print $2}')

  cd - >/dev/null
  rm -rf "$TMP_DIR"

  if [ "$AHEAD" -eq 0 ]; then
    echo "Upstream not ahead, skipping."
    NOCHANGE=$((NOCHANGE + 1))
    continue
  fi

  echo "Upstream ahead by $AHEAD commits → syncing..."

  # ⭐ 开始同步
  rm -rf repo
  git clone "https://$GH_PAT@github.com/$fork.git" repo -q
  cd repo

  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  git remote add upstream "https://github.com/$upstream.git"
  git fetch upstream -q
  git fetch origin --prune --tags -q

  git checkout "$branch" -q
  git reset --hard "origin/$branch" -q

  LOG_FILE="../sync_error.log"
  rm -f "$LOG_FILE"

  MERGE_STATUS="success"
  PUSH_STATUS="success"

  # ⭐ merge-only（保留你的修改）
  git merge -X ours "upstream/$branch" --no-edit >> /dev/null 2>>"$LOG_FILE"
  if [ $? -ne 0 ]; then
    MERGE_STATUS="fail"
  fi

  # ⭐ push（安全覆盖）
  if [ "$MERGE_STATUS" = "success" ]; then
    git push --force-with-lease "https://$GH_PAT@github.com/$fork.git" "$branch" >> /dev/null 2>>"$LOG_FILE"
    if [ $? -ne 0 ]; then
      PUSH_STATUS="fail"
    fi
  else
    PUSH_STATUS="fail"
  fi

  cd ..
  rm -rf repo

  # ⭐ 单仓库通知（失败不显示仓库名）
  if [ "$notify" = "true" ]; then
    if [ "$MERGE_STATUS" = "success" ] && [ "$PUSH_STATUS" = "success" ]; then

      MESSAGE="🎉 *同步成功*\n"
      MESSAGE+="📦 仓库：\`${fork}\`\n"
      MESSAGE+="🌿 分支：\`${branch}\`\n"
      MESSAGE+="🔄 上游：\`${upstream}\`\n"
      MESSAGE+="🆕 Commit：\`${UPSTREAM_SHA}\`"

      SUCCESS_LIST+="• \`${fork}\`（${branch}）\n"

    else
      ERROR_LOG=""
      if [ -f "$LOG_FILE" ]; then
        ERROR_LOG=$(cat "$LOG_FILE")
      fi

      MESSAGE="⚠️ *同步失败*\n"
      MESSAGE+="🆕 上游 Commit：\`${UPSTREAM_SHA}\`\n"
      MESSAGE+="📄 日志：\n\`\`\`\n$ERROR_LOG\n\`\`\`"
    fi

    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
      -d chat_id="$TG_CHAT_ID" \
      -d parse_mode="MarkdownV2" \
      -d text="$MESSAGE" >/dev/null
  fi

  # ⭐ 统计
  if [ "$MERGE_STATUS" = "success" ] && [ "$PUSH_STATUS" = "success" ]; then
    SUCCESS=$((SUCCESS + 1))
  else
    FAILED=$((FAILED + 1))
  fi

done

# ⭐ 最终同步报告（失败不列出仓库名）
REPORT+="📦 总仓库：$TOTAL\n"
REPORT+="🔹 无变化：$NOCHANGE\n"
REPORT+="🟢 成功：$SUCCESS\n"
REPORT+="🔴 失败：$FAILED\n\n"

if [ "$SUCCESS" -gt 0 ]; then
  REPORT+="🎯 *成功列表：*\n$SUCCESS_LIST"
fi

curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
  -d chat_id="$TG_CHAT_ID" \
  -d parse_mode="MarkdownV2" \
  -d text="$REPORT" >/dev/null
