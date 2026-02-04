#!/bin/bash
set -u

CONFIG=$1
# 定义缓存文件路径（建议在 workflow 中配置将此文件 commit 回仓库或使用 actions/cache）
CACHE_FILE="sync_state.json"

# 如果缓存文件不存在，初始化为空 JSON 对象
if [ ! -f "$CACHE_FILE" ]; then
  echo "{}" > "$CACHE_FILE"
fi

TOTAL=0
NOCHANGE=0
SUCCESS=0
FAILED=0
UPDATED_REPOS=""

TZ_TIME=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')

# 检查 jq
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed."
    exit 1
fi

echo "🚀 Starting Sync Job at $TZ_TIME"

# 读取配置循环处理
for row in $(jq -c '.[]' "$CONFIG"); do
  TOTAL=$((TOTAL + 1))

  fork=$(echo "$row" | jq -r '.fork')
  upstream=$(echo "$row" | jq -r '.upstream')
  branch=$(echo "$row" | jq -r '.branch')
  notify=$(echo "$row" | jq -r '.notify')

  echo "------------------------------------------------"
  echo "🔍 Checking $fork ($branch)..."

  # 1. 获取 Upstream 最新 SHA (仅获取目标分支，极快)
  UPSTREAM_API="https://api.github.com/repos/$upstream/commits/$branch"
  UPSTREAM_DATA=$(curl -s -H "Authorization: token $GH_PAT" "$UPSTREAM_API")
  
  # 提取 SHA，如果提取失败（如仓库不存在或鉴权失败），跳过
  UPSTREAM_SHA=$(echo "$UPSTREAM_DATA" | jq -r '.sha')

  if [ "$UPSTREAM_SHA" == "null" ] || [ -z "$UPSTREAM_SHA" ]; then
      echo "⚠️  Failed to fetch upstream SHA for $upstream. Skipping."
      FAILED=$((FAILED + 1))
      continue
  fi

  # 2. 读取缓存中的 SHA
  # 注意：这里使用 fork:branch 作为 key，防止同一个仓库不同分支冲突
  CACHE_KEY="${fork}:${branch}"
  LAST_SYNCED_SHA=$(jq -r --arg key "$CACHE_KEY" '.[$key] // "none"' "$CACHE_FILE")

  echo "   Upstream Latest: ${UPSTREAM_SHA:0:7}"
  echo "   Last Synced:     ${LAST_SYNCED_SHA:0:7}"

  # 3. 对比 SHA：如果一致，说明上游没动过，直接跳过
  if [ "$UPSTREAM_SHA" == "$LAST_SYNCED_SHA" ]; then
      echo "✅ Upstream has not changed since last sync. Skipping."
      NOCHANGE=$((NOCHANGE + 1))
      continue
  fi

  echo "⚡ Update detected (New SHA), starting sync..."

  # ===================== 同步流程 =====================
  rm -rf repo
  # Clone 你的 Fork
  git clone "https://$GH_PAT@github.com/$fork.git" repo
  cd repo || exit

  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  # 添加 upstream
  git remote add upstream "https://github.com/$upstream.git"
  
  # ⭐ 关键修复：只 Fetch 指定分支
  # 语法：git fetch [remote] [remote_branch]:[local_ref]
  # 这里我们将上游的 $branch 映射到本地的 refs/remotes/upstream/$branch
  echo "⬇️  Fetching only upstream/$branch..."
  git fetch upstream "$branch:refs/remotes/upstream/$branch"

  # 切换到目标分支（确保本地环境对齐）
  git checkout "$branch"

  LOG_FILE="../sync_error.log"
  rm -f "$LOG_FILE"
  SYNC_STATUS="success"

  echo "🔄 Merging upstream/$branch (Strategy: ours)..."
  
  # Merge
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

  cd ..
  rm -rf repo

  # ===================== 结果处理 =====================

  if [ "$SYNC_STATUS" = "success" ]; then
    SUCCESS=$((SUCCESS + 1))
    UPDATED_REPOS+="✅ $fork ($branch)%0A"
    
    # ⭐ 更新缓存文件：只有成功 Push 后才更新缓存
    # 使用临时文件原子写入，避免损坏
    jq --arg key "$CACHE_KEY" --arg sha "$UPSTREAM_SHA" '.[$key] = $sha' "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    
  else
    FAILED=$((FAILED + 1))
    
    # 失败发送日志
    ERROR_LOG=""
    if [ -f "$LOG_FILE" ]; then
        ERROR_LOG=$(tail -n 15 "$LOG_FILE")
    fi
    
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

REPORT="📊 *Github 上游同步报告*%0A"
REPORT+="🕒 时间：$TZ_TIME%0A"
REPORT+="%0A"
REPORT+="📦 仓库总数：$TOTAL%0A"
REPORT+="➖ 无变化：$NOCHANGE%0A"
REPORT+="🟢 成功更新：$SUCCESS%0A"
REPORT+="🔴 更新失败：$FAILED%0A"

if [ -n "$UPDATED_REPOS" ]; then
    REPORT+="%0A🚀 *更新列表*：%0A$UPDATED_REPOS"
fi

curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
  -d chat_id="$TG_CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="$REPORT" >/dev/null

echo "✅ All done. Current Cache State:"
cat "$CACHE_FILE"
