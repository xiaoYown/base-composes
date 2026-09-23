#!/usr/bin/env bash
# 日志栈造数: 往三条采集链路发测试日志 (fluent-bit 单容器三入口)
# 用法: ./logs-send.sh [file|http|otlp|all] [每链路条数, 默认 3]
#   file = 追加到 $LOGS_DIR/e2e.log (fluent-bit tail -> lua -> clickhouse)
#   http = POST 127.0.0.1:$FB_HTTP_PORT (fluent-bit 直收, 每行一个 JSON 对象)
#   otlp = POST 127.0.0.1:$OTLP_HTTP_PORT/v1/logs (OTLP/HTTP+JSON 编码, 同 OTel SDK 出口)
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
  # 混一条纯文本 (level 由 lua 关键词粗判)
  printf '[%s] plain-1 ERROR 纯文本文件链路测试日志\n' "$tag" >> "$f"
  echo "file: 已追加 $((n + 1)) 条 -> $LOGS_SRC/e2e.log (标记 $tag)"
}

send_http() {
  ok=0
  for ((i = 1; i <= n; i++)); do
    lv=$(echo "$levels" | cut -d' ' -f$(( (i - 1) % 3 + 1 )))
    code=$(curl -sm 5 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$FB_HTTP_PORT/" \
      -H 'content-type: application/json' \
      -d "{\"service\":\"e2e-http\",\"level\":\"$lv\",\"message\":\"[$tag] http-$i $lv 直推链路测试日志\"}") || code=000
    case "$code" in 2*) ok=$((ok + 1)) ;; esac   # fluent-bit http 输入返回 200/201
  done
  echo "http: 成功 $ok/$n (标记 $tag)"
  [ "$ok" = "$n" ] || exit 1
}

send_otlp() {  # OTLP/HTTP + protobuf (真实 OTel SDK 形态; JSON 手构载荷在 lua extended callback 下会被丢弃)
  # 依赖本机 uv 临时环境 (opentelemetry-sdk); 带 record attrs 验证白名单提取
  uv run --no-project -q --with "opentelemetry-sdk>=1.44" --with "opentelemetry-exporter-otlp-proto-http>=1.44" \
    python -c "
import logging
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter

provider = LoggerProvider(resource=Resource.create({'service.name': 'e2e-otlp'}))
provider.add_log_record_processor(BatchLogRecordProcessor(
    OTLPLogExporter(endpoint='http://127.0.0.1:$OTLP_PORT/v1/logs', timeout=5)))
logging.basicConfig(level=logging.INFO, handlers=[LoggingHandler(level=logging.INFO, logger_provider=provider)], force=True)
log = logging.getLogger('e2e')
levels = ['info', 'warn', 'error']
for i in range($n):
    lv = levels[i % 3]
    getattr(log, lv)('[$tag] otlp-%d %s OTLP 遥测链路测试日志' % (i + 1, lv),
                     extra={'request_id': '$tag', 'stack': 'goroutine 1 [running]:\nmain.e2e()'})
provider.shutdown()
" 2>/dev/null || { echo "otlp: 发送失败 (uv 可用?)" >&2; exit 1; }
  echo "otlp: 已发 $n 条 (标记 $tag, service.name=e2e-otlp)"
}

case "$link" in
  file) send_file ;;
  http)  send_http ;;
  otlp)  send_otlp ;;
  all)   send_file; send_http; send_otlp ;;
esac
echo "查询验证: ./logs-query.sh -t $tag"
