#!/usr/bin/env bash
# 日志栈检索: 按条件查 clickhouse 日志表 (验证追踪/排障用)
# 用法: ./logs-query.sh [-s source] [-l level] [-i file|http|otlp] [-t 关键词] [-m 最近N分钟(10)] [-n 条数(20)]
#   三条链路同表 db_logs.logs, -i 按入口过滤 (attributes.ingress); OTLP 链路 source 兜底 'otlp'
#   例: ./logs-query.sh -t send-1732 -m 5      # 查某次造数的日志
#       ./logs-query.sh -i otlp                # 只看 OTLP 遥测日志
set -uo pipefail
cd "$(dirname "$0")" && . ./_common.sh

src=""; lv=""; ing=""; text=""; mins=10; n=20
while getopts ':s:l:i:t:m:n:h' opt; do
  case "$opt" in
    s) src=$OPTARG ;; l) lv=$OPTARG ;; i) ing=$OPTARG ;;
    t) text=$OPTARG ;;
    m) mins=$OPTARG ;; n) n=$OPTARG ;;
    h) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "参数错误, -h 看用法" >&2; exit 2 ;;
  esac
done

# 入参校验/收口 (枚举防注入)
case "$lv" in ""|info|warn|error|debug|trace) ;; *) echo "level 须为 info/warn/error/debug/trace" >&2; exit 2 ;; esac
case "$ing" in ""|file|http|otlp) ;; *) echo "-i 须为 file/http/otlp" >&2; exit 2 ;; esac
[[ "$mins" =~ ^[0-9]+$ ]] || { echo "-m 须为数字" >&2; exit 2; }
[[ "$n" =~ ^[0-9]+$ ]] || { echo "-n 须为数字" >&2; exit 2; }

where="timestamp > now() - INTERVAL $mins MINUTE"
[ -n "$src" ] && where="$where AND source = '$(sql_quote "$src")'"
[ -n "$lv" ] && where="$where AND level = '$(sql_quote "$lv")'"
[ -n "$ing" ] && where="$where AND attributes['ingress'] = '$(sql_quote "$ing")'"
[ -n "$text" ] && where="$where AND positionCaseInsensitive(message, '$(sql_quote "$text")') > 0"
ch_query "SELECT timestamp, source, level, attributes['ingress'] AS ingress, message FROM db_logs.logs WHERE $where ORDER BY timestamp DESC LIMIT $n FORMAT PrettyCompactMonoBlock"
