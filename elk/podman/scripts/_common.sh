# ELK 日志栈脚本公共库: .env 解析 + clickhouse/fluent-bit 访问封装 (macOS bash 3.2 兼容, 零依赖)
# 不直接执行; 由 logs-*.sh source

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 从 .env 取值 (同 docker compose 规则: 引号值整取, 裸值剥行内注释; 不做 shell 展开), 无则用默认
env_val() {  # $1=变量名 $2=默认值
  local v
  v=$(sed -n "s/^$1=//p" "$ROOT/.env" 2>/dev/null | tail -1)
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
    \'*\') v=${v#\'}; v=${v%\'} ;;
    *)    v=$(printf '%s' "$v" | sed 's/[[:space:]]*#.*$//') ;;
  esac
  printf '%s' "${v:-$2}"
}

CH_HTTP_PORT=$(env_val CLICKHOUSE_HTTP_PORT 8123)
CH_USER=$(env_val CLICKHOUSE_USER admin)
CH_PASS=$(env_val CLICKHOUSE_PASSWORD clickhouse123456)
FB_HTTP_PORT=$(env_val FB_HTTP_PORT 8686)      # fluent-bit 直推入口 (每行一个 JSON 对象)
OTLP_PORT=$(env_val OTLP_HTTP_PORT 4318)       # fluent-bit OTLP/HTTP 入口
LOGS_SRC=$(env_val LOGS_DIR "")                # 文件采集目录 (tail 源)
[ -n "$LOGS_SRC" ] || { echo "请在 .env 配置 LOGS_DIR (且须位于 /Users 或 /var/folders 下)" >&2; exit 1; }

# clickhouse HTTP 查询 (stdout 即结果)
ch_query() { curl -sm 10 "http://127.0.0.1:$CH_HTTP_PORT/" -u "$CH_USER:$CH_PASS" --data-binary "$1"; }

# clickhouse 单值查询 (剥空白)
ch_scalar() { ch_query "$1" | tr -d '[:space:]'; }

# SQL 字符串字面量转义 (单引号)
sql_quote() { printf '%s' "$1" | sed "s/'/\\\\'/g"; }
