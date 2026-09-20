#!/usr/bin/env bash
# work 组中间件: 多选服务再执行 compose 动作 (零依赖, macOS bash 3.2 兼容)
# 用法: ./mw.sh [up|stop|restart]    默认 up (即 up -d)
#   up       启动勾选服务; external 卷 compose 只用不建, 缺失时确认后预建空卷 (全新初始化)
#   stop     停止勾选服务: Enter=仅停容器保留 (compose stop); y=卸载存储 (停+删容器+删数据卷)
#            数据卷是 external, compose down -v 删不掉, 由本脚本解析 compose.yaml 代删
#   restart  重启勾选服务 (只对 running 容器生效, compose 语义)
# 按键: ↑/↓ 移动 | 空格 勾选 | a 全选/清空 | Enter 执行 | q 取消
# 说明: 勾选会连带依赖 (compose depends_on 语义, 如 rocketmq-proxy 自动带起 broker/namesrv)
set -uo pipefail
cd "$(dirname "$0")"

COMPOSE="podman compose -f compose.yaml"

action="${1:-up}"
case "$action" in
  up|stop|restart) ;;
  *) echo "用法: $0 [up|stop|restart]" >&2; exit 2 ;;
esac

# ---- compose.yaml 解析 (awk 零依赖, 卷结构增删无需改脚本) ----

# 顶层 volumes 声明: 输出 "卷key 声明名 ext|int" (external 用声明名; 其余实际名为 <项目名>_key)
volume_decls() {
  awk '
    function emit() { if (key != "") print key, name, (ext ? "ext" : "int") }
    /^volumes:/ { invol = 1; next }
    invol && /^[^ ]/ { invol = 0; emit(); next }
    invol && /^  [-A-Za-z0-9_.]+: *$/ { emit(); key = $0; gsub(/[ :]/, "", key); name = ""; ext = 0; next }
    invol && /^    name:/ { name = $2; gsub(/"/, "", name) }
    invol && /^    external:/ { ext = ($0 ~ /true/) }
    END { emit() }
  ' compose.yaml
}

# 服务 volumes 列表引用的卷 key (一行一个; bind mount 不在顶层声明里, 天然被过滤)
service_volume_keys() {  # $1 = 服务名
  awk -v svc="$1" '
    /^services:$/ { insvc = 1; next }
    insvc && /^[^ ]/ { insvc = 0 }
    insvc && /^  [-A-Za-z0-9_.]+: *$/ { cur = $0; gsub(/[ :]/, "", cur); invol = 0; next }
    insvc && /^    volumes:/ { invol = 1; next }
    insvc && invol && /^ +- / {
      if (cur == svc) { v = $0; sub(/^ +- /, "", v); sub(/:.*/, "", v); print v }
      next
    }
    insvc && invol && /^    [^ ]/ { invol = 0 }
  ' compose.yaml
}

# 勾选服务引用的全部数据卷 → "实际卷名 ext|int" 一行一条 (去重; external 用声明名, 其余 <项目名>_key)
chosen_volumes() {
  local keys=() k s x hit vk vn ve real
  for s in "${chosen[@]}"; do
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      hit=0
      for x in ${keys[@]+"${keys[@]}"}; do [ "$x" = "$k" ] && { hit=1; break; }; done
      [ "$hit" = 1 ] || keys+=("$k")
    done < <(service_volume_keys "$s")
  done
  [ "${#keys[@]}" -gt 0 ] || return 0
  while read -r vk vn ve; do
    [ -n "$vk" ] || continue
    for k in ${keys[@]+"${keys[@]}"}; do
      [ "$k" = "$vk" ] || continue
      real=$vn; [ "$ve" = ext ] || real="work_${vk}"
      echo "$real $ve"
    done
  done < <(volume_decls)
}

# ---- up: external 卷 compose 只用不建, 缺失时确认后预建空卷, 否则 up 直接报卷不存在 ----
up_chosen() {
  local missing=() v kind ans
  while read -r v kind; do
    [ -n "$v" ] || continue
    [ "$kind" = ext ] || continue
    podman volume exists "$v" 2>/dev/null || missing+=("$v")
  done < <(chosen_volumes)
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'external 数据卷缺失: %s\n' "${missing[*]}"
    read -r -p "建空卷全新初始化? [Y/n] (external 卷设计用于继承旧数据; 若本想先迁数据请 n 退出) " ans
    case "$ans" in n|N) echo "已取消"; exit 1 ;; esac
    for v in "${missing[@]}"; do
      podman volume create "$v" >/dev/null && echo "已建空卷: $v (服务按 .env 首次初始化)"
    done
  fi
  echo ">> $COMPOSE up -d ${chosen[*]}"
  exec $COMPOSE up -d "${chosen[@]}"
}

# ---- stop: 停止勾选服务, 可选卸载存储 ----
stop_chosen() {
  local vnames=() v kind podman_vols ans
  podman_vols=$(podman volume ls --format '{{.Name}}' 2>/dev/null)
  # 勾选服务的卷里只保留 podman 中实际存在的
  while read -r v kind; do
    [ -n "$v" ] || continue
    printf '%s\n' "$podman_vols" | grep -qx "$v" && vnames+=("$v")
  done < <(chosen_volumes)

  read -r -p "卸载存储? [y/N] (Enter=仅停止容器; y=停止+删容器+删数据卷) " ans
  case "$ans" in
    y|Y)
      if [ "${#vnames[@]}" -gt 0 ]; then
        printf '将删除数据卷: %s\n' "${vnames[*]}"
        read -r -p "卷内数据 (库/缓存) 将全部丢失, 确认? [y/N] " ans
        case "$ans" in
          y|Y) ;;
          *) echo "已取消卸载, 仅停止容器"; exec $COMPOSE stop "${chosen[@]}" ;;
        esac
      fi
      echo ">> $COMPOSE stop + rm -f ${chosen[*]}"
      $COMPOSE stop "${chosen[@]}"
      $COMPOSE rm -f "${chosen[@]}"
      for v in ${vnames[@]+"${vnames[@]}"}; do
        if podman volume rm "$v"; then echo "已删数据卷: $v"; fi
      done
      ;;
    *)
      echo ">> $COMPOSE stop ${chosen[*]}"
      exec $COMPOSE stop "${chosen[@]}"
      ;;
  esac
}

services=()
while IFS= read -r s; do [ -n "$s" ] && services+=("$s"); done < <($COMPOSE config --services 2>/dev/null | sort)
n=${#services[@]}
if [ "$n" -eq 0 ]; then echo "读取服务清单失败: $COMPOSE config --services" >&2; exit 1; fi

running=$($COMPOSE ps --services --filter status=running 2>/dev/null | tr '\n' ' ' || true)

marked=(); cur=0
for ((i = 0; i < n; i++)); do marked[$i]=0; done

all_marked() {
  for ((i = 0; i < n; i++)); do [ "${marked[$i]}" = 0 ] && return 1; done
  return 0
}

render() {
  local i mark arrow st
  for ((i = 0; i < n; i++)); do
    mark=" ";  arrow=" "; st=""
    if [ "${marked[$i]}" = 1 ]; then mark="x"; fi
    if [ "$i" = "$cur" ]; then arrow=">"; fi
    case " $running " in *" ${services[$i]} "*) st=" (running)" ;; esac
    printf '%s [%s] %s%s\n' "$arrow" "$mark" "${services[$i]}" "$st"
  done
}

printf '\033[1mwork 中间件\033[0m — 空格勾选 · a 全选/清空 · Enter 执行 %s · q 取消\n' "$action"
render
while :; do
  IFS= read -rsn1 key || exit 130
  case "$key" in
    $'\033')
      IFS= read -rsn2 seq || true
      case "$seq" in
        '[A') cur=$(( (cur - 1 + n) % n )) ;;
        '[B') cur=$(( (cur + 1) % n )) ;;
        *)    printf '\a'; continue ;;
      esac ;;
    ' ') marked[$cur]=$(( 1 - marked[$cur] )) ;;
    a|A) if all_marked; then
           for ((i = 0; i < n; i++)); do marked[$i]=0; done
         else
           for ((i = 0; i < n; i++)); do marked[$i]=1; done
         fi ;;
    '')  break ;;
    q|Q) echo; echo "已取消"; exit 130 ;;
    *)   printf '\a'; continue ;;
  esac
  printf '\033[%dA\033[J' "$n"
  render
done

chosen=()
for ((i = 0; i < n; i++)); do
  if [ "${marked[$i]}" = 1 ]; then chosen+=("${services[$i]}"); fi
done
if [ ${#chosen[@]} -eq 0 ]; then echo "未勾选任何服务, 退出"; exit 1; fi

case "$action" in
  up)      up_chosen ;;
  restart)
    echo ">> $COMPOSE restart ${chosen[*]}"
    exec $COMPOSE restart "${chosen[@]}"
    ;;
  stop) stop_chosen ;;
esac
