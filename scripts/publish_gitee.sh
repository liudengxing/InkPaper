#!/usr/bin/env bash
# 把代码与 Release 同步到 Gitee 镜像仓。
#
# 大陆网络直连 GitHub 很慢，所以每次发版后把代码、tag、安装包都推一份到 Gitee，
# 应用内「检查更新」也优先读 Gitee。用法：
#
#   GITEE_TOKEN=xxx TAG=v1.1.76 bash scripts/publish_gitee.sh
#
# 可选环境变量：GITEE_OWNER（默认 liudengxing）、GITEE_REPO（默认 InkPaper）、
# DIST_DIR（默认 dist，放 *.apk / *.aab 与 release_notes.md）、
# MIRROR_ONLY=1（只同步代码与标签，不碰 Release，CI 每次 push main 时用）。
set -euo pipefail

: "${GITEE_TOKEN:?GITEE_TOKEN is required}"
mirror_only="${MIRROR_ONLY:-0}"
if [ "$mirror_only" != "1" ]; then
  : "${TAG:?TAG is required}"
fi

owner="${GITEE_OWNER:-liudengxing}"
repo="${GITEE_REPO:-InkPaper}"
dist="${DIST_DIR:-dist}"
tag="${TAG:-}"
api="https://gitee.com/api/v5/repos/$owner/$repo"

# token 走 URL 时会被 curl 的错误信息带出来，先在日志里打码。
echo "::add-mask::$GITEE_TOKEN" 2>/dev/null || true

echo "== 1/3 同步代码与标签到 gitee.com/$owner/$repo"
git remote remove gitee >/dev/null 2>&1 || true
git remote add gitee "https://oauth2:${GITEE_TOKEN}@gitee.com/${owner}/${repo}.git"
git push gitee --prune "+refs/heads/*:refs/heads/*"
git push gitee "+refs/tags/*:refs/tags/*"

if [ "$mirror_only" = "1" ]; then
  echo "== 只同步代码，跳过 Release（MIRROR_ONLY=1）"
  exit 0
fi

echo "== 2/3 创建 Gitee Release $tag"
body_file="$dist/release_notes.md"
release_id="$(
  curl -sS -X POST "$api/releases?access_token=$GITEE_TOKEN" \
    -d "tag_name=$tag" \
    -d "target_commitish=main" \
    -d "name=InkPaper $tag" \
    --data-urlencode "body@$body_file" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true
)"
if [ -z "$release_id" ]; then
  echo "创建失败（可能已存在），改为读取已有 Release"
  release_id="$(
    curl -sS "$api/releases/tags/$tag?access_token=$GITEE_TOKEN" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))'
  )"
fi
echo "release id: $release_id"

echo "== 3/3 上传安装包"
for f in "$dist"/*.apk "$dist"/*.aab; do
  [ -f "$f" ] || continue
  echo "  upload $(basename "$f")"
  curl -sS -f -X POST \
    "$api/releases/$release_id/attach_files?access_token=$GITEE_TOKEN" \
    -F "file=@$f" >/dev/null
done

echo "== 完成，当前 Release 资产："
curl -sS "$api/releases/latest" \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)
print("tag:", data.get("tag_name"))
for asset in data.get("assets", []):
    print("  ", asset.get("name"), "->", asset.get("browser_download_url"))
'
