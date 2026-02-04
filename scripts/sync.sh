#!/bin/bash
set -e

CONFIG=$1

for row in $(jq -c '.[]' $CONFIG); do
  fork=$(echo $row | jq -r '.fork')
  upstream=$(echo $row | jq -r '.upstream')
  branch=$(echo $row | jq -r '.branch')

  echo "=== Syncing $fork from $upstream ($branch) ==="

  # 克隆 fork 仓库（使用 PAT 认证）
  git clone https://$GH_PAT@github.com/$fork.git repo
  cd repo

  # 添加 upstream
  git remote add upstream https://github.com/$upstream.git

  # 拉取最新 upstream
  git fetch upstream
  git fetch origin

  # 强制 checkout 到 fork 的目标分支
  git checkout -B $branch origin/$branch

  # 合并 upstream 的对应分支
  git merge upstream/$branch --no-edit || true

  # 推送回 fork 仓库
  git push https://$GH_PAT@github.com/$fork.git $branch

  cd ..
  rm -rf repo
done
