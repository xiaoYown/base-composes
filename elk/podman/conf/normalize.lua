-- 归一清洗 (原 vector VRL 逻辑移植): 三入口 -> logs 表列结构
-- 字段来源:
--   tail  = .log (+parser 提升的顶层字段)
--   http  = 顶层字段 (message/level/service)
--   otlp  = record.log (body) + group.resource.attributes (service.name 等 resource 属性)
--           + metadata.otlp (severity_text / record attributes) - lua extended callback
--           (fluent-bit >= 4.0.4 五参形态; 仅 protobuf 路径填充 group/metadata, JSON 手构载荷不保证)
--
-- 属性策略 (2026-09-24 白名单退役, ATTR_KEYS 契约废除): 动态透传, 应用打的标量属性全收,
-- 无键面登记, 新键零改动落库。规则:
--   1) otlp record attributes (metadata.otlp.attributes): 应用主动打的, 全收
--   2) otlp resource attributes (group.resource.attributes): SDK 自动挂的, 滤噪前缀后兜底 (record 优先)
--   3) http/file 入口: parser 提升的顶层杂字段同级提升进 attributes (三入口语义对称)
--   4) 标量 (string/number/boolean) 直转 string; 复合值 (数组/映射) 跳过 - lua 无 cjson,
--      应用侧复合值自行标量化 (如逗号 join)
--   5) 保留键 ingress/file 为管道自产, 入口属性不得覆盖
--   6) metadata.otlp 的 trace_id/span_id (裸字节) 转小写 hex 提升为同名属性; 无 span 上下文则无键
-- 契约一句话: 应用打的标量属性原样出现在 attributes (light-kb 侧 arch-observability 同此表述)

-- SDK 自动挂的 resource 属性降噪前缀 (record 属性是应用主动打的, 不滤)
local NOISE_PFX = {
  "telemetry.sdk.",     -- OTel SDK 自述 (name/language/version)
  "service.instance.",
  "service.version",
  "process.",           -- 部分运行时自动挂进程信息
  "os.",
}

-- 管道保留键: 归一层自产 (ingress 链路标记 / tail 文件名)
local RESERVED = { ["ingress"] = true, ["file"] = true }

-- http/file 入口顶层提升时排除的列消费字段 (已是 logs 表列或 message 来源, 不重复进属性)
local TOP_RESERVED = {
  ["message"] = true, ["log"] = true, ["level"] = true, ["severity_text"] = true,
  ["service"] = true, ["file"] = true, ["ingress"] = true,
}

-- 标量取值: string 非空 / number / boolean 直转 string, 其余 (table/nil/空串) 跳过
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

local function noisy(key)
  for i = 1, #NOISE_PFX do
    local p = NOISE_PFX[i]
    if string.sub(key, 1, string.len(p)) == p then return true end
  end
  return false
end

-- 原始字节转小写 hex (OTel 惯例): metadata.otlp 的 trace_id(16B)/span_id(8B) 是裸字节,
-- 进 Map(String,String) 前转可查询的 hex 文本 (应用若手动打同名属性, 以应用为准)
local function hex_str(s)
  if type(s) ~= "string" or s == "" then return nil end
  local out = {}
  for i = 1, string.len(s) do
    out[i] = string.format("%02x", string.byte(s, i))
  end
  return table.concat(out)
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

  -- 动态属性透传: otlp = trace_id/span_id 提升 + record attrs 全收 + resource attrs 滤噪兜底;
  -- http/file = 顶层杂字段提升。file 仅 tail 入口有值, 空不落键避免属性面常驻空串
  local attrs = { ingress = ingress }
  if file ~= "" then attrs["file"] = file end
  if ingress == "otlp" then
    local tid = hex_str(ot["trace_id"])
    if tid ~= nil then attrs["trace_id"] = tid end
    local sid = hex_str(ot["span_id"])
    if sid ~= nil then attrs["span_id"] = sid end
    for k, v in pairs(ot_attrs) do
      if not RESERVED[k] then
        local s = scalar_str(v)
        if s ~= nil then attrs[k] = s end
      end
    end
    for k, v in pairs(res_attrs) do
      if not RESERVED[k] and attrs[k] == nil and not noisy(k) then
        local s = scalar_str(v)
        if s ~= nil then attrs[k] = s end
      end
    end
  else
    for k, v in pairs(record) do
      if not TOP_RESERVED[k] and not RESERVED[k] then
        local s = scalar_str(v)
        if s ~= nil then attrs[k] = s end
      end
    end
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
