#!/usr/bin/env bash
# 日志栈端到端断言: 三条链路各造一批带唯一标记的日志, 轮询 clickhouse 校验入库条数/入口/级别
# 链路 (fluent-bit 单容器三入口, 全部归一到 db_logs.logs 单表):
#   文件 4 条 (3 JSON + 1 纯文本) 经 tail; HTTP 3 条直推; OTLP 3 条经 OTLP/HTTP 入口 (真实 OTel SDK protobuf)
# 期望: 共 10 条 (ingress file=4/http=3/otlp=3; level: info=3 warn=3 error=4)
#   file 纯文本行走关键词粗判; OTLP severity 经 severity_text 精确归级, resource service.name -> source,
#   record attrs (request_id/stack) 经白名单进 attributes 列 (normalize.lua ATTR_KEYS 双端契约)
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
  code=$(curl -sm 5 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$FB_HTTP_PORT/" \
    -H 'content-type: application/json' \
    -d "{\"service\":\"e2e-http\",\"level\":\"$lv\",\"message\":\"[$tag] h-$lv\"}") || code=000
  case "$code" in 2*) http_ok=$((http_ok + 1)) ;; esac
done
echo "http: $http_ok/3 成功"
[ "$http_ok" = "3" ] || { echo "FAIL: http 直推未全部 2xx (fluent-bit 未启动?)" >&2; exit 1; }

otlp_ok=0
# OTLP 链路造数: 真实 OTel SDK (protobuf) 发 3 条, 带 record attrs (request_id/stack) 验证白名单
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
for lv in ['info', 'warn', 'error']:
    getattr(log, lv)('[$tag] o-%s' % lv, extra={'request_id': '$tag', 'stack': 'goroutine 1 [running]:\nmain.e2e()'})
provider.shutdown()
" 2>/dev/null && otlp_ok=3
echo "otlp: $otlp_ok/3 成功"
[ "$otlp_ok" = "3" ] || { echo "FAIL: OTLP 发送失败 (fluent-bit 未启动 / uv 可用?)" >&2; exit 1; }

# ---- 轮询入库 (文件链路轮询 5s + flush, 留足窗口) ----
total=0
for i in $(seq 1 10); do
  sleep 3
  total=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE position(message, '$tag') > 0 AND timestamp > now() - INTERVAL 3 MINUTE")
  [ "$total" = "10" ] && break
done

echo "入库: $total/10 (logs 表)"
[ "$total" = "10" ] || { echo "FAIL: 数量不符"; ch_query "SELECT timestamp, source, level, attributes, message FROM db_logs.logs WHERE position(message, '$tag') > 0 ORDER BY timestamp FORMAT PrettyCompactMonoBlock"; exit 1; }

# ---- 断言: 入口 / 级别分布 ----
fails=0
check() {  # $1=描述 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $3"; else echo "  FAIL $1 期望 $2 实际 $3"; fails=$((fails + 1)); fi
}
cond="position(message, '$tag') > 0 AND timestamp > now() - INTERVAL 3 MINUTE"

f_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE $cond AND attributes['ingress'] = 'file'")
h_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE $cond AND attributes['ingress'] = 'http'")
o_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE $cond AND attributes['ingress'] = 'otlp'")
err_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE $cond AND level = 'error'")
info_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE $cond AND level = 'info'")
warn_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE $cond AND level = 'warn'")
fsrc_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE $cond AND attributes['ingress'] = 'file' AND source = 'e2e.log'")
osrc_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE $cond AND attributes['ingress'] = 'otlp' AND source = 'e2e-otlp'")
oattr_cnt=$(ch_scalar "SELECT count() FROM db_logs.logs WHERE $cond AND attributes['ingress'] = 'otlp' AND attributes['request_id'] = '$tag' AND length(attributes['stack']) > 0")

check "文件链路 (tail -> lua -> ch)" 4 "$f_cnt"
check "直推链路 (http 入口)" 3 "$h_cnt"
check "OTLP 链路 (opentelemetry 入口)" 3 "$o_cnt"
check "level=error (含纯文本粗判)" 4 "$err_cnt"
check "level=info" 3 "$info_cnt"
check "level=warn" 3 "$warn_cnt"
check "文件链路 source=文件名" 4 "$fsrc_cnt"
check "OTLP source=service.name" 3 "$osrc_cnt"
check "OTLP 白名单属性入库 (request_id/stack)" 3 "$oattr_cnt"

if [ "$fails" = "0" ]; then echo "PASS: 日志追踪链路正常"; exit 0; fi
echo "FAIL: $fails 项断言未过, 明细:"
ch_query "SELECT timestamp, source, level, attributes, message FROM db_logs.logs WHERE $cond ORDER BY timestamp FORMAT PrettyCompactMonoBlock"
exit 1
