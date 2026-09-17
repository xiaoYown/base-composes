#!/usr/bin/env bash
# work 组中间件: 多选服务再执行 compose 动作 (零依赖, macOS bash 3.2 兼容)
# 用法: ./up.sh [up|down|stop|restart]    默认 up (即 up -d); down 只删容器不动数据卷
# 按键: ↑/↓ 移动 | 空格 勾选 | a 全选/清空 | Enter 执行 | q 取消
# 说明: 勾选会连带依赖自动起 (compose depends_on 语义, 如 rocketmq-proxy 自动带起 broker/namesrv)
set -uo pipefail
cd "$(dirname "$0")"

COMPOSE="podman compose -f compose.yaml"

case "${1:-up}" in
  up)               DC="up -d" ;;
  down|stop|restart) DC="$1" ;;
  *) echo "用法: $0 [up|down|stop|restart]" >&2; exit 2 ;;
esac

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

printf '\033[1mwork 中间件\033[0m — 空格勾选 · a 全选/清空 · Enter 执行 %s · q 取消\n' "$DC"
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

echo ">> $COMPOSE $DC ${chosen[*]}"
$COMPOSE $DC "${chosen[@]}"
