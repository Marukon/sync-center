#!/bin/bash
set -u

# 接收配置文件路径
CONFIG=$1
CACHE_FILE="sync_state.json"

# ================= INIT =================
# 如果缓存文件不存在，初始化为空 JSON
if [ ! -f "$CACHE_FILE" ]; then
  echo "{}" > "$CACHE_FILE"
fi

TOTAL=0
NOCHANGE=0
SUCCESS=0
FAILED=0
UPDATED_REPOS=""
FAILED_REPOS=""

# 获取东八区时间
TZ_TIME=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')

# 依赖检查
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed."
    exit 1
fi

echo "🚀 Starting Sync Job at $TZ_TIME"

# ================= LOOP =================
for row in $(jq -c '.[]' "$CONFIG"); do
  TOTAL=$((TOTAL + 1))

  # 解析 JSON 配置
  fork=$(echo "$row" | jq -r '.fork')
  upstream=$(echo "$row" | jq -r '.upstream')
  branch=$(echo "$row" | jq -r '.branch')
  notify=$(echo "$row" | jq -r '.notify')

  echo "------------------------------------------------"
  echo "🔍 Checking $fork ($branch)..."

  # [STEP 1] 获取 Upstream 特定分支的最新 SHA
  UPSTREAM_API="https://api.github.com/repos/$upstream/commits/$branch"
  UPSTREAM_DATA=$(curl -s -H "Authorization: token $GH_PAT" "$UPSTREAM_API")
  UPSTREAM_SHA=$(echo "$UPSTREAM_DATA" | jq -r '.sha')

  # 异常处理
  if [ "$UPSTREAM_SHA" == "null" ] || [ -z "$UPSTREAM_SHA" ]; then
      echo "⚠️  Failed to fetch upstream SHA for $upstream. Skipping."
      FAILED=$((FAILED + 1))
      FAILED_REPOS+="❌ $fork ($branch)%0A"
      continue
  fi

  # [STEP 2] 读取本地缓存对比
  CACHE_KEY="${fork}:${branch}"
  LAST_SYNCED_SHA=$(jq -r --arg key "$CACHE_KEY" '.[$key] // "none"' "$CACHE_FILE")

  echo "   Upstream Latest: ${UPSTREAM_SHA:0:7}"
  echo "   Last Synced:     ${LAST_SYNCED_SHA:0:7}"

  # 缓存命中：跳过
  if [ "$UPSTREAM_SHA" == "$LAST_SYNCED_SHA" ]; then
      echo "✅ No changes (Cache Hit). Skipping."
      NOCHANGE=$((NOCHANGE + 1))
      continue
  fi

  echo "⚡ Update detected (New SHA), syncing..."

  # ================= SYNC PROCESS =================
  rm -rf repo
  
  # Clone 你的 Fork 仓库
  git clone "https://$GH_PAT@github.com/$fork.git" repo
  cd repo || exit

  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  # 添加上游源
  git remote add upstream "https://github.com/$upstream.git"
  
  echo "⬇️  Fetching ONLY upstream/$branch (No Tags)..."
  # 只拉取上游指定分支
  git fetch --no-tags upstream "$branch:refs/remotes/upstream/$branch"

  echo "🔀 Checking out branch..."
  if ! git checkout -B "$branch" "origin/$branch"; then
      echo "❌ Checkout failed! (Branch might not exist on origin?)"
      FAILED=$((FAILED + 1))
      FAILED_REPOS+="❌ $fork ($branch)%0A"
      cd ..
      rm -rf repo
      continue
  fi

  LOG_FILE="../sync_error.log"
  rm -f "$LOG_FILE"
  SYNC_STATUS="success"

  echo "🔄 Merging..."
  
  MERGE_OUTPUT=$(git merge -X ours "upstream/$branch" --no-edit --allow-unrelated-histories 2>&1 | tee "$LOG_FILE")
  MERGE_EXIT_CODE=${PIPESTATUS[0]}

  if [ $MERGE_EXIT_CODE -ne 0 ]; then
      echo "❌ Merge failed!"
      SYNC_STATUS="fail"
  else
      if echo "$MERGE_OUTPUT" | grep -q "Already up to date"; then
          echo "✅ Already up to date (No actual changes needed)."
          SYNC_STATUS="skipped_push"
      else
          echo "✅ Merge success, pushing..."
          if ! git push "https://$GH_PAT@github.com/$fork.git" "$branch" &>> "$LOG_FILE"; then
              echo "❌ Push failed!"
              SYNC_STATUS="fail"
          fi
      fi
  fi

  cd ..
  rm -rf repo

  # ================= UPDATE CACHE & REPORT =================

  if [ "$SYNC_STATUS" = "success" ] || [ "$SYNC_STATUS" = "skipped_push" ]; then
    
    if [ "$SYNC_STATUS" = "success" ]; then
        SUCCESS=$((SUCCESS + 1))
        UPDATED_REPOS+="✅ $fork ($branch)%0A"
    else
        NOCHANGE=$((NOCHANGE + 1))
    fi
    
    jq --arg key "$CACHE_KEY" --arg sha "$UPSTREAM_SHA" '.[$key] = $sha' "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    
  else
    FAILED=$((FAILED + 1))
    FAILED_REPOS+="❌ $fork ($branch)%0A"
    
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

# ================= FINAL REPORT =================

if [ "$TOTAL" -eq "$NOCHANGE" ]; then
    echo "ℹ️ No changes detected. No Telegram notification sent."
    exit 0
fi


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

if [ -n "$FAILED_REPOS" ]; then
    REPORT+="%0A💥 *失败列表*：%0A$FAILED_REPOS"
fi

curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
  -d chat_id="$TG_CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="$REPORT" >/dev/null

echo "✅ All done."
