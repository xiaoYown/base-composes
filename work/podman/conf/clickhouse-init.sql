-- 日志表初始化 (幂等; compose: clickhouse-init 服务, __TTL_DAYS__ 由 sed 注入 $LOG_TTL_DAYS)
-- 改保留期对已建表无效, 需 ALTER TABLE db_logs.logs MODIFY TTL ...
CREATE DATABASE IF NOT EXISTS db_logs;
CREATE TABLE IF NOT EXISTS db_logs.logs (
    timestamp   DateTime64(3) CODEC(Delta, ZSTD(1)),
    message     String CODEC(ZSTD(3)),
    level       LowCardinality(String),
    source      LowCardinality(String),
    host        LowCardinality(String),
    attributes  Map(String, String) CODEC(ZSTD(1)),
    INDEX token_msg message TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 4
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (source, timestamp)
TTL toDateTime(timestamp) + INTERVAL __TTL_DAYS__ DAY
SETTINGS ttl_only_drop_parts = 1;
