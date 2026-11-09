#!/usr/bin/env bash
# 把失败步骤的日志浓缩成 check annotation。
#
# 为什么需要它：GitHub 对一个失败的步骤只显示「Process completed with exit code 1」，
# 完整 job logs 需要 token 才能读。而 check annotation 在公开仓库是匿名可读的
# （GET /repos/{owner}/{repo}/commits/{sha}/check-runs → output.annotations_url），
# 所以把关键行转成 ::error::，没有 token 的场合也能定位失败原因。
#
# 用法：bash scripts/ci_annotate.sh <日志文件>
set -uo pipefail

log="${1:-}"
if [ -z "$log" ] || [ ! -f "$log" ]; then
  echo "ci_annotate: no log at '$log', nothing to annotate."
  exit 0
fi

{
  echo "== 已执行的子命令 =="
  grep -E '^> ' "$log" | tail -n 4
  echo "== Gradle / Dart 具体失败段 =="
  sed -n '/What went wrong/,+10p' "$log" | head -n 11
  echo "== 疑似错误行 =="
  grep -E 'issues found|Some tests failed|Execution failed|error:|Error:|FAILURE' "$log" \
    | tail -n 6
  echo "== 日志尾部 =="
  tail -n 5 "$log"
} 2>/dev/null \
  | awk '!seen[$0]++' \
  | head -n 14 \
  | sed 's/^/::error::/'
