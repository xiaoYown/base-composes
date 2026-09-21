#!/usr/bin/env bash
# 日志栈造数: 往三条采集链路发测试日志
# 用法: ./logs-send.sh [file|http|otlp|all] [每链路条数, 默认 3]
#   file = 追加到 data/fluent-bit/e2e.log (fluent-bit tail -> forward -> vector -> clickhouse)
#   http = POST 127.0.0.1:$VECTOR_HTTP_PORT (vector 直收, 自定义 JSON)
#   otlp = POST 127.0.0.1:$VECTOR_OTLP_HTTP_PORT/v1/logs (OTLP/HTTP+JSON 编码, 同 OTel SDK 出口)
# level 轮换 info/warn/error, file 混合 JSON 行与纯文本行 (纯文本走关键词粗判)
set -uo pipefail
cd "$(dirname "$0")" && . ./_common.sh

link="${1:-all}"; n="${2:-3}"
case "$link" in file|http|otlp|all) ;; *) echo "用法: $0 [file|http|otlp|all] [条数]" >&2; exit 2 ;; esac
[[ "$n" =~ ^[0-9]+$ ]] || { echo "条数须为数字" >&2; exit 2; }

tag="send-$(date +%s)-$RANDOM"
levels="info warn error"

send_file() {
  mkdir -p "$LOGS_SRC"; f="$LOGS_SRC/e2e.log"
  for ((i = 1; i <= n; i++)); do
    lv=$(echo "$levels" | cut -d' ' -f$(( (i - 1) % 3 + 1 )))
    printf '%s\n' "{\"service\":\"e2e\",\"level\":\"$lv\",\"message\":\"[$tag] file-$i $lv 文件链路测试日志\"}" >> "$f"
  done
  # 混一条纯文本 (level 由 vector 关键词粗判)
  printf '[%s] plain-1 ERROR 纯文本文件链路测试日志\n' "$tag" >> "$f"
  echo "file: 已追加 $((n + 1)) 条 -> data/fluent-bit/e2e.log (标记 $tag)"
}

send_http() {
  ok=0
  for ((i = 1; i <= n; i++)); do
    lv=$(echo "$levels" | cut -d' ' -f$(( (i - 1) % 3 + 1 )))
    code=$(curl -sm 5 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$VECTOR_PORT" \
      -H 'content-type: application/json' \
      -d "{\"service\":\"e2e-http\",\"level\":\"$lv\",\"message\":\"[$tag] http-$i $lv 直推链路测试日志\"}") || code=000
    [ "$code" = "200" ] && ok=$((ok + 1))
  done
  echo "http: 成功 $ok/$n (标记 $tag)"
  [ "$ok" = "$n" ] || exit 1
}

send_otlp() {  # OTLP/HTTP + JSON 编码 (protobuf-JSON 映射), 等价 OTel SDK 的 logs exporter
  ok=0
  for ((i = 1; i <= n; i++)); do
    lv=$(echo "$levels" | cut -d' ' -f$(( (i - 1) % 3 + 1 )))
    sev=$(echo "$lv" | tr '[:lower:]' '[:upper:]')
    body=$(printf '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"e2e-otlp"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"%s000000000","severityText":"%s","body":{"stringValue":"[%s] otlp-%s %s OTLP 遥测链路测试日志"}}]}]}]}' \
      "$(date +%s)" "$sev" "$tag" "$i" "$lv")
    code=$(curl -sm 5 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$OTLP_PORT/v1/logs" \
      -H 'content-type: application/json' -d "$body") || code=000
    [ "$code" = "200" ] && ok=$((ok + 1))
  done
  echo "otlp: 成功 $ok/$n (标记 $tag)"
  [ "$ok" = "$n" ] || exit 1
}

case "$link" in
  file) send_file ;;
  http)  send_http ;;
  otlp)  send_otlp ;;
  all)   send_file; send_http; send_otlp ;;
esac
echo "查询验证: ./logs-query.sh -t $tag"
