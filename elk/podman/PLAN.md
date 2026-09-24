# ELK 日志栈: 轻量化改造与自研计划

> 2026-09-22 自 work/podman 日志栈裁撤迁出。本文档是现状说明 + 后续自研 UI 的路线图, 留在本地供迭代参考。

## 1. 改造背景与结果

原方案 (work/podman 内 6 服务, 生产级三层流水线架在本地开发场景):

```
fluent-bit -> vector (VRL 清洗/攒批) -> clickhouse (db_logs.logs)
                                      <- otelcol (OTLP -> db_logs.otel_logs)
                                      <- grafana (查询 UI, 首启联网装插件)
```

问题: vector 与 fluent-bit 同机同 compose, 是纯冗余的一跳; grafana UI 体验差且首启依赖联网;
6 个容器对本地开发过重。

**现方案 (2 长驻容器, 单表归一):**

```
                       ┌─ tail  $LOGS_DIR/*.log          (tag logs.file)
fluent-bit (单容器) ───┼─ http  127.0.0.1:8686 JSON 行   (tag logs.http)  ── lua 归一 ──> out_http (gzip
                       └─ otlp  127.0.0.1:4318 OTLP/HTTP (tag logs.otlp)                    JSONEachRow 批量)
clickhouse 26.3  <────────────────────────────────────────────────────────────────────────────┘
  db_logs.logs (单表三链路, attributes.ingress 区分; TTL $LOG_TTL_DAYS 天, 按天分区, tokenbf 索引)
```

- grafana 移除: 查询过渡期用 `scripts/logs-query.sh` 或 clickhouse-client; 长期走自研 UI (见 §3)。
- clickhouse-init 移除: 建表折叠进 `/docker-entrypoint-initdb.d` (数据卷首次初始化时执行, 幂等)。
- VRL 清洗移植为 `conf/normalize.lua` (level 粗判 / source 取文件名 / ingress 标记 / RFC3339 毫秒)。
- 运维: `./mw.sh` (多选 up/stop/重启, 同 work 组习惯); 验证: `./scripts/logs-e2e.sh` (三链路 10 条断言)。

## 2. 实施中的关键事实 (迭代时须知道)

1. **fluent-bit 5.0.10 官方镜像无 clickhouse 输出插件** (上游有, 默认构建不含, 实测报 plugin not found)。
   故用内置 http 输出发 JSONEachRow: URI 是编码后的
   `INSERT INTO db_logs.logs SETTINGS date_time_input_format='best_effort', input_format_skip_unknown_fields=1 FORMAT JSONEachRow`
   (conf/fluent-bit.conf 的 [OUTPUT] 段, 勿手改编码)。
2. **fluent-bit 发行版是 distroless (无 shell)**, 且 **podman machine (projects) 只挂载了 /Users 与
   /var/folders** (/Volumes/* 均 bind 不可用, 实测)。因此配置走本地 build 打进镜像:
   改 `conf/` 后需 `podman compose -f compose.yaml build fluent-bit && podman compose -f compose.yaml up -d fluent-bit`。
   LOGS_DIR 必须位于 /Users 或 /var/folders 下。
3. **clickhouse entrypoint 陷阱**: `/entrypoint.sh clickhouse-server` (带非 `--` 开头参数) 会跳过
   用户/库/initdb 初始化直接 exec; 必须不带参数调用 (compose 里 command 生成 00-logs.sql 后 `exec /entrypoint.sh`)。
4. **[PARSER] 段在 5.0 不允许放主配置文件**, 须独立 parsers.conf (`-R` 参数)。
5. **OTLP 输入的字段映射** (2026-09-23 复测修订, light-kb otel-logging 期): OTLP logs 的
   severity/attributes/resource 属性不在 record body, 而在 log event 的 metadata root field 与 group —
   lua 经 **extended callback (5 参形态, fluent-bit >= 4.0.4 按参数个数自动检测)** 读取:
   `group.resource.attributes` -> source (service.name) 与 resource 属性 (滤噪后兜底);
   `metadata.otlp` -> severity_text (level) / record attributes (全收) / trace_id+span_id (裸字节, lua 转 hex 提升)。
   旧结论 "resource 属性不透传" 是 3 参 classic callback 只见 body map 所致。
   **仅 protobuf 路径填充 group/metadata** (真实 OTel SDK 默认编码); JSON 手构载荷在 5 参 lua 下被丢弃,
   造数/e2e 一律走 OTel SDK (uv 临时环境)。
   **属性契约 (2026-09-24 白名单退役)**: ATTR_KEYS 已废除, 改动态透传 —— 应用打的标量属性全收
   (otlp record attrs 全收; http/file 顶层杂字段同级提升; resource attrs 滤噪前缀
   telemetry.sdk./service.instance./service.version/process./os. 后兜底; 复合值跳过, 应用侧自行标量化;
   保留键 ingress/file)。无键面登记, 新键零改动落库, 不再存在双端清单同步。
6. **OTLP 仅接了 logs 信号**; 未来要 traces/metrics 时再加回 otelcol (旧配置在 git 历史)。
7. 数据链路可靠性: tail 偏移 DB 持久化防重采 (fluentbit-state 卷); out_http `Retry_Limit False`
   无限重试 (与原 vector 语义一致); gzip 批量降低 CH parts 写放大。
8. 回滚: 本目录之前的 vector/otelcol/grafana 形态完整保留在仓库 git 历史 (work/podman 旧路径),
   revert 对应 commit 即可整体恢复。

## 3. 自研 UI 计划 (核心目标: 换掉 grafana 的查询体验)

**底座优势**: ClickHouse 8123 HTTP 接口是自研 UI 最友好的后端 —— 单 POST 出 JSONEachRow,
零 SDK, 任何薄后端/静态页可直接对接。127.0.0.1:8123 已对宿主发布 (Basic auth)。

### 阶段 1 — 只读查询账号 + 直查 (半天)
- CH 建只读账号 (BFF/脚本一律不用 admin, readonly 兜底拼装失误): `CREATE USER ui_ro ... SETTINGS readonly=1`
  + 行策略限 db_logs; 记入本目录文档。
- 临时查询: `curl -u ui_ro:*** "http://127.0.0.1:8123/?default_format=JSONEachRow" --data-binary "SELECT ..."`。
- 常用查询模板 (BFF 端点直接用):
  - 时间窗过滤: `WHERE timestamp > now() - INTERVAL {n} MINUTE`
  - 链路过滤: `attributes['ingress'] = 'file'|'http'|'otlp'`
  - 关键词: `positionCaseInsensitive(message, 'xxx') > 0` (tokenbf 索引已建, 长词更快)
  - 直方图: `SELECT toStartOfMinute(timestamp) t, count() FROM db_logs.logs WHERE ... GROUP BY t`
  - 聚合面板: `SELECT source, level, count() FROM ... GROUP BY GROUPING SETS ((source),(level))`

### 阶段 2 — Go 单二进制: BFF + 前端一体 (1-2 天, 方案已定 2026-09-22)
**技术决策: Go 单二进制 (`go:embed` 前端产物 + 薄 BFF), 不引入 Caddy, 不用 Node。**
- 否掉 "Caddy 纯静态 + 前端直连 CH": 浏览器直连 8123 须改 CH 的 CORS/OPTIONS 配置 (动基础设施层),
  只读凭据永久下放浏览器, 阶段 3 复杂查询还得返工加后端; 而 Caddy 的能力 (TLS/反代/多站点)
  在本场景全用不上 —— Go 标准库 `http.FileServer` 发静态文件已足够。
- 不用 Node 同时意味着前端**无构建链**: 纯 ES modules + vendor 进仓库的轻库 (Preact+htm ~13KB
  或 Alpine.js), 虚拟滚动 vendor 小实现或手写; 哪天要 TS/JSX 再上构建, embed 不关心产物来源。
- 形态 (单 main 包):
  - 端点: `/api/logs` `/api/histogram` `/api/sources` 参数化, SQL 模板复用 §1 验证过的;
    CH 凭据从 .env 只进后端, 前端零凭据; 静态资源 go:embed, 同源免 CORS。
  - `-dev` flag: dev 模式 serve 本地目录 (`os.DirFS`) 替代 embed, 前端改动免重编译。
  - 页面: 时间范围 + source/level/ingress/关键词过滤 + 虚拟滚动日志流 +
    类 tail -f 轮询追读 (`timestamp > 上次最大值` 增量拉)。
- 部署: 宿主直接 `go run` / 二进制, **零新增容器** (契合本分组轻量哲学);
  将来愿意再进 compose 作第三服务 (同 fluent-bit 走本地 build)。

### 阶段 3 — 增强 (按需)
- 错误聚合 (按 source+level 分组趋势)、日志上下文 (同 source 前后 N 条)、
  OTLP trace_id 关联跳转 (管道侧已自动提升 span 上下文的 trace_id/span_id, 待应用侧启用 tracer 后即有数据;
  见 §2.5)、属性键动态发现 (loupe 侧 arrayJoin(mapKeys(attributes)) facets)。
- 若接 traces (otelcol 回归), UI 加 trace 检索页。
- ~~attributes 白名单透传 + OTLP 入口 service 兜底~~ (2026-09-23 已完成, 随 light-kb
  otel-logging 期落地: normalize.lua extended callback + ATTR_KEYS 白名单, source=service.name,
  e2e 增白名单断言; 见 §2.5)。
- ~~ATTR_KEYS 白名单退役, 改动态透传~~ (2026-09-24 完成: 标量属性全收 + resource 滤噪兜底 +
  http/file 顶层提升 + trace_id/span_id 自动提升; 动机是白名单三端漂移 (lua 24 键 / loupe 6 键 /
  light-kb 文档) 与新键接入需 rebuild 的维护环, 详见 §2.5 属性契约)。

### 明确不做
- 不做告警/采集器下沉/多机聚合 (本地开发场景, 保持 2 容器底座);
- 不再引入 grafana/可观测全家桶组件 —— 查询体验走自研;
- 不引入 Caddy/nginx 等独立静态服务与 Node 工具链 (理由见阶段 2 技术决策)。

## 4. 遗留验证点

- OTLP gRPC (4317) 未发布: OTel SDK 侧须用 http/protobuf 协议
  (`OTEL_EXPORTER_OTLP_PROTOCOL=http_protobuf`, endpoint `http://127.0.0.1:4318`)。
  2026-09-23 已实测确认 (Python SDK 默认即 protobuf): JSON 编码载荷在 5 参 lua 下被丢弃, protobuf 路径完整。
- tail 首扫边界: fluent-bit 启动前已写入文件的旧行不保证回采 (实测增量追加可靠);
  e2e 脚本始终以追加方式造数, 与真实应用写日志行为一致。
- 高频写入 (万条/秒级) 未压测: 本地开发量级远低于此, out_http 1s flush + gzip 批量应有余量。
