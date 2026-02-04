#!/bin/bash
# 移除 set -e，手动控制错误流程
set -u 

CONFIG=$1

# 初始化计数器
TOTAL=0
NOCHANGE=0
SUCCESS=0
FAILED=0

# 初始化列表用于报告
UPDATED_REPOS=""

# 设置时区和时间 (UTC+8)
TZ_TIME=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')

# 检查 jq
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed."
    exit 1
fi

echo "🚀 Starting Sync Job at $TZ_TIME"

for row in $(jq -c '.[]' "$CONFIG"); do
  TOTAL=$((TOTAL + 1))

  fork=$(echo "$row" | jq -r '.fork')
  upstream=$(echo "$row" | jq -r '.upstream')
  branch=$(echo "$row" | jq -r '.branch')
  notify=$(echo "$row" | jq -r '.notify')

  echo "------------------------------------------------"
  echo "🔍 Checking $fork ($branch)..."

  # =========================================================
  # 核心修复：使用 Compare API 智能判断是否需要更新
  # Base: 我的 Fork ($branch)
  # Head: 上游 ($upstream:$branch)
  # =========================================================
  COMPARE_URL="https://api.github.com/repos/$fork/compare/$branch...$upstream:$branch"
  
  COMPARE_RES=$(curl -s -H "Authorization: token $GH_PAT" "$COMPARE_URL")
  STATUS=$(echo "$COMPARE_RES" | jq -r '.status')
  AHEAD_BY=$(echo "$COMPARE_RES" | jq -r '.ahead_by')

  # 调试输出
  echo "   Status: $STATUS | Upstream is ahead by: $AHEAD_BY commits"

  # 逻辑判断：
  # identical: 完全一致 -> 跳过
  # behind: 上游比我还旧（我改了很多，上游没动）-> 跳过
  # ahead: 上游有更新 -> 同步
  # diverged: 上游有更新，我也有修改 -> 同步
  if [ "$STATUS" == "identical" ] || [ "$STATUS" == "behind" ]; then
    echo "✅ No upstream changes detected."
    NOCHANGE=$((NOCHANGE + 1))
    continue
  fi

  echo "⚡ Update detected ($STATUS), syncing..."

  # ===================== 同步流程 =====================
  rm -rf repo
  git clone "https://$GH_PAT@github.com/$fork.git" repo
  cd repo || exit

  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  git remote add upstream "https://github.com/$upstream.git"
  git fetch upstream

  git checkout "$branch"
  # 这里不reset，防止丢失本地未push的修改（虽然Actions环境是新的，但保险起见）
  # 主要是确保我们在正确的分支上
  
  LOG_FILE="../sync_error.log"
  rm -f "$LOG_FILE"
  SYNC_STATUS="success"

  echo "🔄 Merging upstream changes (Strategy: ours)..."
  
  # 使用 merge -X ours 保留你的修改
  if ! git merge -X ours "upstream/$branch" --no-edit --allow-unrelated-histories &> "$LOG_FILE"; then
      echo "❌ Merge failed!"
      cat "$LOG_FILE"
      SYNC_STATUS="fail"
  else
      echo "✅ Merge success, pushing..."
      if ! git push "https://$GH_PAT@github.com/$fork.git" "$branch" &>> "$LOG_FILE"; then
          echo "❌ Push failed!"
          SYNC_STATUS="fail"
      fi
  fi
  
  # 获取上游最新 Commit SHA 用于日志
  UPSTREAM_SHA=$(git rev-parse upstream/$branch)

  cd ..
  rm -rf repo

  # ===================== 结果处理 =====================

  if [ "$SYNC_STATUS" = "success" ]; then
    SUCCESS=$((SUCCESS + 1))
    # 将成功的仓库加入名单，用于最终汇总
    UPDATED_REPOS+="✅ $fork ($branch)%0A"
    
    # 成功通常不需要单条通知，除非 notify=true 且你非常想看，
    # 但根据你的要求，成功只在汇总里体现，这里就不发单条了。
    # 如果你坚持要单条成功通知，可以在这里保留，但建议删掉以减少打扰。
  else
    FAILED=$((FAILED + 1))
    
    # ⚠️ 失败情况：必须单独发送日志
    ERROR_LOG=""
    if [ -f "$LOG_FILE" ]; then
        # 截取最后15行日志
        ERROR_LOG=$(tail -n 15 "$LOG_FILE")
    fi
    
    # URL 编码一些特殊字符防止 curl 报错
    FAIL_MSG="❌ Sync Failed%0A"
    FAIL_MSG+="Repo: $fork%0A"
    FAIL_MSG+="Branch: $branch%0A"
    FAIL_MSG+="Upstream: $upstream%0A%0A"
    FAIL_MSG+="📝 Log:%0A$ERROR_LOG"

    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
      -d chat_id="$TG_CHAT_ID" \
      -d text="$FAIL_MSG" >/dev/null
  fi

done

# ===================== 最终报告生成 =====================

# 构建精简报告
REPORT="📊 *Github 上游同步报告*%0A"
REPORT+="🕒 时间：$TZ_TIME%0A"
REPORT+="%0A"
REPORT+="📦 仓库总数：$TOTAL%0A"
REPORT+="➖ 无变化：$NOCHANGE%0A"
REPORT+="🟢 成功更新：$SUCCESS%0A"
REPORT+="🔴 更新失败：$FAILED%0A"

# 如果有更新成功的，列出名字
if [ -n "$UPDATED_REPOS" ]; then
    REPORT+="%0A🚀 *更新列表*：%0A$UPDATED_REPOS"
fi

# 只有在有更新或有失败时才发送报告，或者你想每次都发也可以
# 这里默认每次都发
curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
  -d chat_id="$TG_CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="$REPORT" >/dev/null

echo "✅ All done."
