#!/usr/bin/env bash
# 把代码与 Release 同步到 Gitee 镜像仓。
#
# 大陆网络直连 GitHub 很慢，所以每次发版后把代码、tag、APK 都推一份到 Gitee，
# 应用内「检查更新」也优先读 Gitee。用法：
#
#   GITEE_TOKEN=xxx TAG=v1.1.76 bash scripts/publish_gitee.sh
#
# 可选环境变量：GITEE_OWNER（默认 liudengxing233）、GITEE_REPO（默认 ink-paper）、
# DIST_DIR（默认 dist，放 *.apk 与 release_notes.md；AAB 不上传，见第 3 步注释）、
# MIRROR_ONLY=1（只同步代码与标签，不碰 Release，CI 每次 push main 时用）。
set -euo pipefail

: "${GITEE_TOKEN:?GITEE_TOKEN is required}"
mirror_only="${MIRROR_ONLY:-0}"
if [ "$mirror_only" != "1" ]; then
  : "${TAG:?TAG is required}"
fi

owner="${GITEE_OWNER:-liudengxing233}"
repo="${GITEE_REPO:-ink-paper}"
dist="${DIST_DIR:-dist}"
tag="${TAG:-}"
api="https://gitee.com/api/v5/repos/$owner/$repo"

# token 走 URL 时会被 curl 的错误信息带出来，先在日志里打码。
echo "::add-mask::$GITEE_TOKEN" 2>/dev/null || true

echo "== 1/3 同步代码与标签到 gitee.com/$owner/$repo"
# 用户名必须是真实用户名，填 oauth2 之类的占位符 Gitee 会认证失败。
git remote remove gitee >/dev/null 2>&1 || true
git remote add gitee "https://${owner}:${GITEE_TOKEN}@gitee.com/${owner}/${repo}.git"
# 退出时把带 token 的 remote 删掉，避免残留在 .git/config 里。
trap 'git remote remove gitee >/dev/null 2>&1 || true' EXIT
# 用 HEAD 显式推到 main，不要写 --prune "refs/heads/*:refs/heads/*"：
# tag 触发的 checkout 是 detached HEAD，本地一个分支都没有，--prune 会把远端 main
# 当成「本地已删除的分支」去删，Gitee 拒绝删除当前分支，整步直接失败。
# 镜像仓语义是「完全跟随 GitHub」，所以用 + 前缀强制覆盖。
git push gitee "+HEAD:refs/heads/main"
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

echo "== 3/3 上传安装包（只传 APK）"
# 为什么不传 AAB：AAB 只给 Google Play 上传用，国内用户根本下载不到它，
# 传上去等于多传 52 MB。而 Gitee 的附件上传通道在 GitHub Actions 机房里非常不稳，
# 1.1.74 / 1.1.76 / 1.1.79 / 1.1.80 四次发版都卡在这一步，最后一个跑到 job 超时才被发现。
# 只传 APK 把字节数砍半，是这条链路上最有效的一刀。
# 重跑同一次发布时不重复上传同名附件。
existing="$(
  curl -sS "$api/releases/$release_id?access_token=$GITEE_TOKEN" \
    | python3 -c 'import json,sys; print("\n".join(a.get("name","") for a in json.load(sys.stdin).get("assets") or []))'
)"

shopt -s nullglob
apks=("$dist"/*.apk)
shopt -u nullglob
if [ ${#apks[@]} -eq 0 ]; then
  echo "::error::$dist 下没有 APK，无法上传"
  exit 1
fi

# 关键在 --speed-limit / --speed-time：连续 120 秒低于 20 KB/s 就主动断开重来。
# 没有这两个参数时 curl 会一直挂着不报错，只能等 6 小时的 job 超时。
upload_asset() {
  local file="$1" name="$2" attempt
  for attempt in 1 2; do
    echo "  upload $name（第 $attempt 次）"
    if curl -sS -f -X POST \
      --connect-timeout 30 \
      --max-time 1200 \
      --speed-limit 20480 \
      --speed-time 120 \
      --http1.1 \
      -w '  -> HTTP %{http_code}，%{size_upload} 字节，%{time_total}s，%{speed_upload} B/s\n' \
      "$api/releases/$release_id/attach_files?access_token=$GITEE_TOKEN" \
      -F "file=@$file"; then
      return 0
    fi
    echo "  .. 第 $attempt 次失败，15 秒后重试" >&2
    sleep 15
  done
  return 1
}

failed=""
for f in "${apks[@]}"; do
  name="$(basename "$f")"
  if printf '%s\n' "$existing" | grep -Fxq "$name"; then
    echo "  已存在，跳过 $name"
    continue
  fi
  upload_asset "$f" "$name" || failed="$failed $name"
done

if [ -n "$failed" ]; then
  echo "::error::Gitee 附件上传失败：$failed（GitHub Release 已经发好了，可以本地补传）"
  exit 1
fi

echo "== 完成，当前 Release 资产："
curl -sS "$api/releases/latest" \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)
print("tag:", data.get("tag_name"))
for asset in data.get("assets", []):
    print("  ", asset.get("name"), "->", asset.get("browser_download_url"))
'
