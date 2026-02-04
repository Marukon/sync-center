#!/bin/bash
set -e

CONFIG=$1

for row in $(jq -c '.[]' $CONFIG); do
  fork=$(echo $row | jq -r '.fork')
  upstream=$(echo $row | jq -r '.upstream')
  branch=$(echo $row | jq -r '.branch')

  echo "=== Syncing $fork from $upstream ($branch) ==="

  git clone https://github.com/$fork.git repo
  cd repo

  git remote add upstream https://github.com/$upstream.git
  git fetch upstream

  git checkout -B $branch origin/$branch
  git merge upstream/$branch --no-edit || true

  git push origin $branch

  cd ..
  rm -rf repo
done
