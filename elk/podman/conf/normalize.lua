-- 归一清洗 (原 vector VRL 逻辑移植): 三入口 -> logs 表列结构
-- 字段来源:
--   tail  = .log (+parser 提升的顶层字段)
--   http  = 顶层字段 (message/level/service)
--   otlp  = record.log (body) + group.resource.attributes (service.name 等 resource 属性)
--           + metadata.otlp (severity_text / record attributes) - lua extended callback
--           (fluent-bit >= 4.0.4 五参形态; 仅 protobuf 路径填充 group/metadata, JSON 手构载荷不保证)
-- 白名单 ATTR_KEYS 是与 light-kb (arch-observability) 的双端契约, 改清单须双端同步

-- 键面来源: light-kb Go 侧全仓日志键普查 (slog 键值对), 按使用面分组
local ATTR_KEYS = {
  -- 通用: 身份与错误
  "service.name", "request_id", "trace_id", "err", "stack", "event", "error",
  -- 任务与编排 (ingest / taskflow)
  "job_id", "lane", "caller", "type",
  -- 依赖探活 (dep_probe / supervised / server_deps 汇总)
  "dep", "status", "attempts", "deps", "down",
  -- 数据定位
  "kb_id", "doc_id", "tenant_id", "table",
  -- 访问日志 (httpx AccessLog)
  "method", "path", "duration_ms",
  -- 异常 (Python traceback 自动映射)
  "exception.type", "exception.message", "exception.stacktrace",
}

-- 白名单取值: string 非空 / number / boolean 直转 string, 其余 (table/nil/空串) 跳过
local function scalar_str(v)
  local t = type(v)
  if t == "string" then
    if v ~= "" then return v end
    return nil
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  end
  return nil
end

function normalize(cb_tag, ts, group, metadata, record)
  local ingress = "http"
  if cb_tag == "logs.file" then
    ingress = "file"
  elseif cb_tag == "logs.otlp" then
    ingress = "otlp"
  end

  local message = record["message"]
  if message == nil then message = record["log"] end
  if type(message) ~= "string" then message = tostring(message) end

  -- otlp record 级元数据与 resource 属性 (JSON 路径或缺, 防御 nil)
  local ot = {}
  if type(metadata) == "table" and type(metadata["otlp"]) == "table" then ot = metadata["otlp"] end
  local ot_attrs = {}
  if type(ot["attributes"]) == "table" then ot_attrs = ot["attributes"] end
  local res_attrs = {}
  if type(group) == "table" and type(group["resource"]) == "table"
      and type(group["resource"]["attributes"]) == "table" then
    res_attrs = group["resource"]["attributes"]
  end

  local level = record["level"]
  if level == nil then level = record["severity_text"] end
  if level == nil then level = ot["severity_text"] end
  if type(level) ~= "string" or level == "" then
    local up = string.upper(message)
    if string.find(up, "ERROR", 1, true) or string.find(up, "FATAL", 1, true) then
      level = "error"
    elseif string.find(up, "WARN", 1, true) then
      level = "warn"
    elseif string.find(up, "DEBUG", 1, true) or string.find(up, "TRACE", 1, true) then
      level = "debug"
    else
      level = "info"
    end
  else
    level = string.lower(level)
  end

  local source = record["service"]
  if type(source) ~= "string" then source = "" end
  local file = record["file"]
  if type(file) ~= "string" then file = "" end
  if file ~= "" then
    source = string.match(file, "[^/]+$") or file
  end
  if source == "" and ingress == "otlp" then
    local sn = res_attrs["service.name"]   -- OTLP resource 属性经 extended callback group 提取
    if type(sn) == "string" and sn ~= "" then
      source = sn
    else
      source = "otlp"                       -- 兜底链路名 (JSON 手构载荷等无 resource 形态)
    end
  end
  if source == "" then source = "app" end

  local host = "fluent-bit"
  pcall(function()
    local h = os.getenv("FB_HOST")
    if h and h ~= "" then host = h end
  end)

  -- 白名单属性: record attrs 优先, resource attrs 兜底 (service.name 恒来自 resource)
  -- file 仅 tail 入口有值 (OTLP/http 入口无此概念), 空不落键避免属性面常驻空串
  local attrs = { ingress = ingress }
  if file ~= "" then attrs["file"] = file end
  for _, key in ipairs(ATTR_KEYS) do
    local v = scalar_str(ot_attrs[key])
    if v == nil then v = scalar_str(res_attrs[key]) end
    if v ~= nil then attrs[key] = v end
  end

  -- epoch -> RFC3339 毫秒 UTC (CH 端 date_time_input_format=best_effort 解析)
  local sec = math.floor(ts)
  local msec = math.floor((ts - sec) * 1000 + 0.5)
  if msec >= 1000 then sec = sec + 1; msec = 0 end
  local iso = string.format("%s.%03dZ", os.date("!%Y-%m-%dT%H:%M:%S", sec), msec)

  local meta_out = metadata
  if type(meta_out) ~= "table" then meta_out = {} end
  return 1, 0, meta_out, {
    timestamp = iso,
    message = message,
    level = level,
    source = source,
    host = host,
    attributes = attrs
  }
end
