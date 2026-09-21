#!/usr/bin/env bash
# 日志栈端到端断言: 三条链路各造一批带唯一标记的日志, 轮询 clickhouse 校验入库条数/来源/级别
# 链路: 文件 4 条 (3 JSON + 1 纯文本) 经 fluent-bit; HTTP 3 条直推 vector; OTLP 3 条经 otelcol (独立表 otel_logs)
# 期望: logs 表 7 条 (ingress file=4/http=3, level: info=2 warn=2 error=3); otel_logs 表 3 条 (ServiceName=e2e-otlp)
set -uo pipefail
cd "$(dirname "$0")" && . ./_common.sh

tag="e2e-$(date +%s)-$RANDOM"
echo "标记: $tag"

# ---- 造数 ----
mkdir -p "$LOGS_SRC"; f="$LOGS_SRC/e2e.log"
printf '%s\n' \
  "{\"service\":\"e2e\",\"level\":\"info\",\"message\":\"[$tag] f1 info\"}" \
  "{\"service\":\"e2e\",\"level\":\"warn\",\"message\":\"[$tag] f2 warn\"}" \
  "{\"service\":\"e2e\",\"level\":\"error\",\"message\":\"[$tag] f3 error\"}" \
  "[$tag] f4 plain ERROR line" >> "$f"
echo "file: 4 条已追加"

http_ok=0
for lv in info warn error; do
  code=$(curl -sm 5 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$VECTOR_PORT" \
    -H 'content-type: application/json' \
    -d "{\"service\":\"e2e-http\",\"level\":\"$lv\",\"message\":\"[$tag] h-$lv\"}") || code=000
  [ "$code" = "200" ] && http_ok=$((http_ok + 1))
done
echo "http: $http_ok/3 成功"
[ "$http_ok" = "3" ] || { echo "FAIL: http 直推未全部 200 (vector 未启动?)" >&2; exit 1; }

otlp_ok=0
for lv in info warn error; do
  sev=$(echo "$lv" | tr '[:lower:]' '[:upper:]')
  body=$(printf '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"e2e-otlp"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"%s000000000","severityText":"%s","body":{"stringValue":"[%s] o-%s"}}]}]}]}' \
    "$(date +%s)" "$sev" "$tag" "$lv")
  code=$(curl -sm 5 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$OTLP_PORT/v1/logs" \
    -H 'content-type: application/json' -d "$body") || code=000
  [ "$code" = "200" ] && otlp_ok=$((otlp_ok + 1))
done
echo "otlp: $otlp_ok/3 成功"
[ "$otlp_ok" = "3" ] || { echo "FAIL: OTLP 未全部 200 (otelcol 未启动?)" >&2; exit 1; }

# ---- 轮询入库 (文件链路 fluent-bit 轮询 5s + flush/batch, 留足窗口; OTLP 在独立表 otel_logs) ----
total=0
for i in $(seq 1 10); do
  sleep 3
  total=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE position(message, '$tag') > 0 AND timestamp > now() - INTERVAL 3 MINUTE")
  [ "$total" = "7" ] && break
done

echo "入库: $total/7 (logs 表)"
[ "$total" = "7" ] || { echo "FAIL: 数量不符"; ch_query "SELECT timestamp, source, level, message FROM db_logs.logs WHERE position(message, '$tag') > 0 ORDER BY timestamp FORMAT PrettyCompactMonoBlock"; exit 1; }

# ---- 断言: 来源 / 级别分布 ----
fails=0
check() {  # $1=描述 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $3"; else echo "  FAIL $1 期望 $2 实际 $3"; fails=$((fails + 1)); fi
}

f_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE position(message, '$tag') > 0 AND attributes['ingress'] = 'file'")
h_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE position(message, '$tag') > 0 AND attributes['ingress'] = 'http'")
err_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE position(message, '$tag') > 0 AND level = 'error'")
info_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE position(message, '$tag') > 0 AND level = 'info'")
warn_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE position(message, '$tag') > 0 AND level = 'warn'")

check "文件链路 (fluent-bit -> vector)" 4 "$f_cnt"
check "直推链路 (vector http)" 3 "$h_cnt"
check "level=error (含纯文本粗判)" 3 "$err_cnt"
check "level=info" 2 "$info_cnt"
check "level=warn" 2 "$warn_cnt"

# OTLP 表 (otelcol -> clickhouse exporter)
o_cnt=$(ch_scalar "SELECT count() FROM db_logs.otel_logs WHERE position(Body, '$tag') > 0")
o_src=$(ch_scalar "SELECT count() FROM db_logs.otel_logs WHERE position(Body, '$tag') > 0 AND ServiceName = 'e2e-otlp'")
check "OTLP 遥测入库 (otel_logs 表)" 3 "$o_cnt"
check "OTLP ServiceName 提取 (resource)" 3 "$o_src"

if [ "$fails" = "0" ]; then echo "PASS: 日志追踪链路正常"; exit 0; fi
echo "FAIL: $fails 项断言未过, 明细:"
ch_query "SELECT timestamp, source, level, message FROM db_logs.logs WHERE position(message, '$tag') > 0 ORDER BY timestamp FORMAT PrettyCompactMonoBlock"
ch_query "SELECT Timestamp, ServiceName, SeverityText, Body FROM db_logs.otel_logs WHERE position(Body, '$tag') > 0 ORDER BY Timestamp FORMAT PrettyCompactMonoBlock"
exit 1
