-- 归一清洗 (原 vector VRL 逻辑移植): 三入口 -> logs 表列结构
-- 字段来源: tail=.log(+parser 提升的顶层字段)/http=顶层字段/otlp=.log+嵌套 .otlp.severity_text
function normalize(cb_tag, ts, record)
  local ingress = "http"
  if cb_tag == "logs.file" then
    ingress = "file"
  elseif cb_tag == "logs.otlp" then
    ingress = "otlp"
  end

  local message = record["message"]
  if message == nil then message = record["log"] end
  if type(message) ~= "string" then message = tostring(message) end

  local level = record["level"]
  if level == nil then level = record["severity_text"] end
  if level == nil and type(record["otlp"]) == "table" then
    level = record["otlp"]["severity_text"]   -- otlp 输入的 severity 在嵌套表
  end
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
  if source == "" and ingress == "otlp" then source = "otlp" end   -- OTLP resource 属性不透传, 兜底链路名
  if source == "" then source = "app" end

  local host = "fluent-bit"
  pcall(function()
    local h = os.getenv("FB_HOST")
    if h and h ~= "" then host = h end
  end)

  -- epoch -> RFC3339 毫秒 UTC (CH 端 date_time_input_format=best_effort 解析)
  local sec = math.floor(ts)
  local msec = math.floor((ts - sec) * 1000 + 0.5)
  if msec >= 1000 then sec = sec + 1; msec = 0 end
  local iso = string.format("%s.%03dZ", os.date("!%Y-%m-%dT%H:%M:%S", sec), msec)

  return 1, 0, {
    timestamp = iso,
    message = message,
    level = level,
    source = source,
    host = host,
    attributes = { ingress = ingress, file = file }
  }
end
