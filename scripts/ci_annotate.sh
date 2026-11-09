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
  grep -E '^> ' "$log" | tail -n 3
  echo "== 关键错误（按出现顺序取前 7 条）=="
  grep -E 'What went wrong|Caused by|Could not|Could not resolve|UnknownHost|SSL|HTTP [0-9]|Execution failed|Exception|issues found|Some tests failed|error:|Error:' "$log" \
    | head -n 7
  echo "== 日志尾部 =="
  tail -n 5 "$log"
} 2>/dev/null \
  | awk '!seen[$0]++' \
  | head -n 16 \
  | sed 's/^/::error::/'
