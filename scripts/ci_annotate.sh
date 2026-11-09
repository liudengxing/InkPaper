#!/usr/bin/env bash
# 把失败步骤的日志浓缩成一条 check annotation。
#
# 为什么需要它：GitHub 对一个失败的步骤只显示「Process completed with exit code 1」，
# 完整 job logs 需要 token 才能读。而 check annotation 在公开仓库是匿名可读的
# （GET /repos/{owner}/{repo}/commits/{sha}/check-runs → output.annotations_url），
# 所以把关键行塞进一条 ::error::，没有 token 的场合也能定位失败原因。
#
# 一条而不是多条：多行内容用 %0A 转义后合并，避免 GitHub 把每行拆成独立 annotation
# 导致顺序错乱、真正的原因被淹没。
#
# 用法：bash scripts/ci_annotate.sh <日志文件>
set -uo pipefail

log="${1:-}"
if [ -z "$log" ] || [ ! -f "$log" ]; then
  echo "ci_annotate: no log at '$log', nothing to annotate."
  exit 0
fi

body=$({
  echo "== 已执行的子命令 =="
  grep -E '^> ' "$log" | tail -n 3
  echo
  echo "== What went wrong 之后 =="
  # Gradle 的真正原因几乎总在这行之后，旧版只按关键词抽行，把这段漏掉了
  awk '/\* What went wrong:/{f=1; next} f && c<20 {print; c++}' "$log"
  echo
  echo "== 关键错误行 =="
  grep -E 'What went wrong|Caused by|Could not|UnknownHost|SSL|HTTP [0-9]|e: file|issues found|Some tests failed|error:|Error:' "$log" \
    | head -n 10
  echo
  echo "== 日志尾部 =="
  tail -n 6 "$log"
} 2>/dev/null | awk '!seen[$0]++')

if [ -z "$body" ]; then
  echo "ci_annotate: nothing matched in '$log'."
  exit 0
fi

# ::error:: 命令里 % 必须转义、换行写成 %0A，否则会被截断或吞掉
escaped="${body//'%'/'%25'}"
escaped="${escaped//$'\r'/}"
escaped="${escaped//$'\n'/'%0A'}"

echo "::error title=构建失败原因::$escaped"
