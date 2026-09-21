#!/usr/bin/env bash
# 日志栈检索: 按条件查 clickhouse 日志表 (验证追踪/排障用)
# 用法: ./logs-query.sh [-o] [-s source] [-l level] [-t 关键词] [-m 最近N分钟(10)] [-n 条数(20)]
#   -o 查 OTLP 遥测表 db_logs.otel_logs (默认查 file/http 链路的 db_logs.logs)
#   例: ./logs-query.sh -t send-1732 -m 5      # 查某次造数的日志
#       ./logs-query.sh -o -t e2e              # 查 OTel SDK 上报的遥测日志
set -uo pipefail
cd "$(dirname "$0")" && . ./_common.sh

src=""; lv=""; text=""; mins=10; n=20; otel=0
while getopts ':os:l:t:m:n:h' opt; do
  case "$opt" in
    o) otel=1 ;;
    s) src=$OPTARG ;; l) lv=$OPTARG ;; t) text=$OPTARG ;;
    m) mins=$OPTARG ;; n) n=$OPTARG ;;
    h) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "参数错误, -h 看用法" >&2; exit 2 ;;
  esac
done

# 入参校验/收口 (level 枚举; 数字项防注入)
case "$lv" in ""|info|warn|error|debug|trace) ;; *) echo "level 须为 info/warn/error/debug/trace" >&2; exit 2 ;; esac
[[ "$mins" =~ ^[0-9]+$ ]] || { echo "-m 须为数字" >&2; exit 2; }
[[ "$n" =~ ^[0-9]+$ ]] || { echo "-n 须为数字" >&2; exit 2; }

if [ "$otel" = "1" ]; then
  # OTLP 表 (otelcol 建): SeverityText 为大写, source 对应 ServiceName
  where="Timestamp > now() - INTERVAL $mins MINUTE"
  [ -n "$src" ] && where="$where AND ServiceName = '$(sql_quote "$src")'"
  [ -n "$lv" ] && where="$where AND lower(SeverityText) = '$(sql_quote "$lv")'"
  [ -n "$text" ] && where="$where AND positionCaseInsensitive(Body, '$(sql_quote "$text")') > 0"
  ch_query "SELECT Timestamp, ServiceName, lower(SeverityText) AS level, Body AS message FROM db_logs.otel_logs WHERE $where ORDER BY Timestamp DESC LIMIT $n FORMAT PrettyCompactMonoBlock"
else
  where="timestamp > now() - INTERVAL $mins MINUTE"
  [ -n "$src" ] && where="$where AND source = '$(sql_quote "$src")'"
  [ -n "$lv" ] && where="$where AND level = '$(sql_quote "$lv")'"
  [ -n "$text" ] && where="$where AND positionCaseInsensitive(message, '$(sql_quote "$text")') > 0"
  ch_query "SELECT timestamp, source, level, message FROM db_logs.logs WHERE $where ORDER BY timestamp DESC LIMIT $n FORMAT PrettyCompactMonoBlock"
fi
