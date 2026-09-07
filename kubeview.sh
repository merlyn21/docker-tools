#!/usr/bin/env bash
# kubeview — drill-down TUI над kubectl (движок: fzf).
#
#   Экран 1  kubeconfig   файлы из ~/.kube; preview — контексты и cluster-info.
#                         Enter — открыть · Esc — выход.
#                         Если конфиг один — экран пропускается (сразу namespace).
#   Экран 2  namespace    список ns выбранного конфига; ←/→ — сменить
#                         kubeconfig-файл; preview — счётчики ресурсов.
#                         Enter — открыть · Esc — назад к экрану 1.
#   Экран 3  ресурсы      ←/→ — вид (pods · deployments · services),
#                         ↑/↓ — по ресурсам; справа preview: логи пода
#                         (--tail=200, все контейнеры) либо describe.
#                         Enter    — pod: shell внутри контейнера (bash/sh);
#                                    deploy/svc: describe в pager
#                         Ctrl-O   — describe + логи в pager (любой вид)
#                         Ctrl-G   — follow логов пода
#                         Ctrl-R   — обновить · Esc — назад к экрану 2.
#
# Крошки «файл · context · ns · nodes N · CPU used/alloc · RAM used/alloc» —
# на нижней грани внешней рамки (CPU/RAM — сумма по нодам, used из
# metrics-server; кэш 45 с, Ctrl-R обновляет).
# Чтение — get / describe / logs; Enter по поду делает kubectl exec -it.
#
# Требуется fzf >= 0.53 (в apt Ubuntu он старее). Если fzf нет или он старый —
# скрипт предложит скачать свежий бинарь в ~/.local/bin. Форсировать: --install-fzf.
# Свой бинарь: KUBEVIEW_FZF=/path/to/fzf
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
KUBE_DIR="${KUBEVIEW_DIR:-$HOME/.kube}"
STATE="${TMPDIR:-/tmp}/kubeview.$(id -u)"
KCFGFILE="$STATE/kubeconfig"
NSFILE="$STATE/namespace"
KINDFILE="$STATE/kind"
NODEFILE="$STATE/nodes"
ERRF="$STATE/err"
mkdir -p "$STATE"

KINDS=(pods deployments services)
TIMEOUT=8s

FZF="${KUBEVIEW_FZF:-}"          # можно указать конкретный бинарь fzf
FZF_MIN_MINOR=53                 # нужны --list-border / transform-*-label (fzf 0.53+)
LOCAL_BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"

# ---- colours (on unless NO_COLOR / --help) ----------------------------------
if [[ -n "${NO_COLOR:-}" || "${1:-}" == -h || "${1:-}" == --help ]]; then
  C_RESET= C_DIM= C_BOLD= C_REV= C_RED= C_GRN= C_YEL= C_BLU= C_MAG= C_CYN=
else
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_REV=$'\033[7m'
  C_RED=$'\033[31m';  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m';  C_MAG=$'\033[35m'; C_CYN=$'\033[36m'
fi

die() { printf '%s\n' "$*" >&2; exit 1; }

# ---- state -----------------------------------------------------------------
get_kcfg() { cat "$KCFGFILE" 2>/dev/null || true; }
get_ns()   { cat "$NSFILE"   2>/dev/null || true; }
get_kind() { cat "$KINDFILE" 2>/dev/null || echo pods; }

kc() { kubectl --kubeconfig "$(get_kcfg)" --request-timeout="$TIMEOUT" "$@"; }

_kcfg_paths() {
  local f
  for f in "$KUBE_DIR"/*; do
    [[ -f "$f" ]] || continue
    grep -qE '^(apiVersion:|clusters:|current-context:|kind:[[:space:]]*Config)' "$f" 2>/dev/null || continue
    printf '%s\n' "$f"
  done | sort
}

ctx_of() { kubectl --kubeconfig "$1" config current-context 2>/dev/null || echo '?'; }

# jq helper: относительный возраст из ISO-таймстампа
JQ_AGO='def ago($t): if ($t|type)!="string" or $t=="" then "-" else
  (($now|tonumber) - ($t|fromdateiso8601)) as $s |
  if   $s < 0     then "0s"
  elif $s < 3600  then "\(($s/60)|floor)m"
  elif $s < 86400 then "\(($s/3600)|floor)h"
  else "\(($s/86400)|floor)d" end end;'

# ==========================================================================
#  LISTS
# ==========================================================================
cmd_kcfg_list() {
  local f ctx
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    ctx="$(ctx_of "$f")"
    printf '%s\t%s◆%s %s%-30s%s %s→ %s%s\n' \
      "$f" "$C_MAG" "$C_RESET" "$C_BOLD" "$(basename "$f")" "$C_RESET" \
      "$C_DIM" "$ctx" "$C_RESET"
  done < <(_kcfg_paths)
}

cmd_ns_list() {
  local kcfg out; kcfg="$(get_kcfg)"
  [[ -n "$kcfg" ]] || { printf '!\t%s(kubeconfig не выбран)%s\n' "$C_RED" "$C_RESET"; return 0; }
  if ! out="$(kc get ns -o json 2>"$ERRF")"; then
    printf '!\t%s%s%s\n' "$C_RED" "$(head -1 "$ERRF")" "$C_RESET"; return 0
  fi
  printf '%s' "$out" \
    | jq -r '.items[] | [.metadata.name, (.status.phase // "?")] | @tsv' \
    | while IFS=$'\t' read -r name phase; do
        [[ -n "$name" ]] || continue
        local col=$C_GRN; [[ "$phase" == Active ]] || col=$C_YEL
        printf '%s\t%s●%s %s%-34s%s %s%s%s\n' \
          "$name" "$col" "$C_RESET" "$C_BOLD" "$name" "$C_RESET" "$C_DIM" "$phase" "$C_RESET"
      done
  return 0
}

cmd_res_list() {
  local ns kind; ns="$(get_ns)"; kind="$(get_kind)"
  [[ -n "$ns" ]] || { printf '!\t \t%s(namespace не выбран)%s\n' "$C_RED" "$C_RESET"; return 0; }
  case "$kind" in
    pods)        _list_pods    "$ns" ;;
    deployments) _list_deploys "$ns" ;;
    services)    _list_svcs    "$ns" ;;
  esac
}

_list_pods() {
  local ns="$1" out
  if ! out="$(kc get pods -n "$ns" -o json 2>"$ERRF")"; then
    printf '!\t \t%s%s%s\n' "$C_RED" "$(head -1 "$ERRF")" "$C_RESET"; return 0
  fi
  printf '%s' "$out" | jq -r --arg now "$(date +%s)" "$JQ_AGO"'
    .items[] |
    ( if .metadata.deletionTimestamp then "Terminating"
      else
        ([ .status.containerStatuses[]? | .state.waiting.reason // empty ]) as $w |
        ([ .status.containerStatuses[]? | .state.terminated.reason // empty ]) as $tm |
        if   ($w  | length) > 0 then $w[0]
        elif ($tm | length) > 0 and (.status.phase != "Succeeded") then $tm[0]
        else .status.phase end
      end ) as $st |
    [ .metadata.name,
      "\(([.status.containerStatuses[]? | select(.ready)] | length))/\(.spec.containers | length)",
      $st,
      (([.status.containerStatuses[]? | .restartCount] | add) // 0),
      ago(.metadata.creationTimestamp)
    ] | @tsv' \
  | while IFS=$'\t' read -r name ready st restarts age; do
      [[ -n "$name" ]] || continue
      local col=$C_GRN
      case "$st" in
        Running)                                   col=$C_GRN ;;
        Completed|Succeeded)                        col=$C_DIM ;;
        Pending|ContainerCreating|PodInitializing|Init:*|Terminating) col=$C_YEL ;;
        *)                                          col=$C_RED ;;
      esac
      local rc=$C_DIM; [[ "$restarts" -gt 0 ]] 2>/dev/null && rc=$C_YEL
      printf 'pods\t%s\t%s●%s %s%-44s%s %s%-5s%s %s%-20s%s %s↻%-3s%s %s%s%s\n' \
        "$name" "$col" "$C_RESET" \
        "$C_BOLD" "$name" "$C_RESET" \
        "$C_DIM" "$ready" "$C_RESET" \
        "$col" "$st" "$C_RESET" \
        "$rc" "$restarts" "$C_RESET" \
        "$C_DIM" "$age" "$C_RESET"
    done
  return 0
}

_list_deploys() {
  local ns="$1" out
  if ! out="$(kc get deployments -n "$ns" -o json 2>"$ERRF")"; then
    printf '!\t \t%s%s%s\n' "$C_RED" "$(head -1 "$ERRF")" "$C_RESET"; return 0
  fi
  printf '%s' "$out" | jq -r --arg now "$(date +%s)" "$JQ_AGO"'
    .items[] |
    [ .metadata.name,
      "\(.status.readyReplicas // 0)/\(.spec.replicas // 0)",
      (.status.updatedReplicas   // 0),
      (.status.availableReplicas  // 0),
      ago(.metadata.creationTimestamp),
      ([.spec.template.spec.containers[]?.image] | join(", "))
    ] | @tsv' \
  | while IFS=$'\t' read -r name ready upd avail age images; do
      [[ -n "$name" ]] || continue
      local want="${ready#*/}" have="${ready%/*}" col=$C_YEL
      if   [[ "$want" == 0 ]];        then col=$C_DIM
      elif [[ "$have" == "$want" ]];  then col=$C_GRN
      elif [[ "$have" == 0 ]];        then col=$C_RED
      fi
      printf 'deployments\t%s\t%s◆%s %s%-40s%s %s%-8s%s %sup:%s av:%s%s  %s%s%s  %s%s%s\n' \
        "$name" "$col" "$C_RESET" \
        "$C_BOLD" "$name" "$C_RESET" \
        "$col" "$ready" "$C_RESET" \
        "$C_DIM" "$upd" "$avail" "$C_RESET" \
        "$C_DIM" "$age" "$C_RESET" \
        "$C_DIM" "$images" "$C_RESET"
    done
  return 0
}

_list_svcs() {
  local ns="$1" out
  if ! out="$(kc get services -n "$ns" -o json 2>"$ERRF")"; then
    printf '!\t \t%s%s%s\n' "$C_RED" "$(head -1 "$ERRF")" "$C_RESET"; return 0
  fi
  printf '%s' "$out" | jq -r --arg now "$(date +%s)" "$JQ_AGO"'
    .items[] |
    [ .metadata.name,
      (.spec.type // "ClusterIP"),
      (.spec.clusterIP // "-"),
      ([.spec.ports[]? | "\(.port)\(if .nodePort then ":"+(.nodePort|tostring) else "" end)/\(.protocol)"] | join(",")),
      ago(.metadata.creationTimestamp)
    ] | @tsv' \
  | while IFS=$'\t' read -r name type cip ports age; do
      [[ -n "$name" ]] || continue
      local col=$C_MAG
      case "$type" in
        NodePort|LoadBalancer) col=$C_CYN ;;
        ExternalName)          col=$C_DIM ;;
      esac
      printf 'services\t%s\t%s◆%s %s%-36s%s %s%-13s%s %s%-16s%s %s%s%s  %s%s%s\n' \
        "$name" "$col" "$C_RESET" \
        "$C_BOLD" "$name" "$C_RESET" \
        "$col" "$type" "$C_RESET" \
        "$C_DIM" "$cip" "$C_RESET" \
        "$C_DIM" "$ports" "$C_RESET" \
        "$C_DIM" "$age" "$C_RESET"
    done
  return 0
}

# ==========================================================================
#  HEADERS / LABELS
# ==========================================================================
cmd_crumb() {
  local kcfg ns nodes; kcfg="$(get_kcfg)"; ns="$(get_ns)"
  [[ -n "$kcfg" ]] || { printf ' (kubeconfig не выбран) '; return; }
  [[ -n "$ns" ]] || ns='—'
  nodes="$(_nodes_cached)"
  printf ' %s · ctx %s · ns %s%s ' \
    "$(basename "$kcfg")" "$(ctx_of "$kcfg")" "$ns" "${nodes:+   ┃   $nodes}"
}

# ---- nodes: агрегат CPU/RAM по всем нодам (used / allocatable) --------------
_nodes_cached() {
  local f="$NODEFILE" age
  if [[ -f "$f" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    [[ "$age" -lt 45 ]] && { cat "$f"; return; }
  fi
  if _nodescan > "$f.tmp" 2>/dev/null && [[ -s "$f.tmp" ]]; then
    mv "$f.tmp" "$f"
  else
    rm -f "$f.tmp"
  fi
  cat "$f" 2>/dev/null || true
}

_nodescan() {
  local kcfg totals used ht=1; kcfg="$(get_kcfg)"
  [[ -n "$kcfg" ]] || return 1
  # без regex-функций jq (test/capture) — работает и на jq без oniguruma
  totals="$(kubectl --kubeconfig "$kcfg" --request-timeout="$TIMEOUT" get nodes -o json 2>/dev/null | jq -r '
    def cpu: tostring as $s |
      if ($s|endswith("m")) then ($s[:-1]|tonumber)/1000 else ($s|tonumber) end;
    def mem: tostring as $s |
      ( ["Ki","Mi","Gi","Ti","Pi","k","K","M","G","T"]
        | map(select($s|endswith(.)))[0] ) as $u |
      ( {"Ki":1024,"Mi":1048576,"Gi":1073741824,"Ti":1099511627776,"Pi":1125899906842624,
         "k":1000,"K":1000,"M":1000000,"G":1000000000,"T":1000000000000}[$u] // 1 ) as $mult |
      ( if $u then ($s[:($s|length)-($u|length)]|tonumber) else ($s|tonumber) end ) * $mult;
    [ .items[] ] as $n |
    "\($n|length) \(([$n[].status.allocatable.cpu|cpu]|add)//0) \(([$n[].status.allocatable.memory|mem]|add)//0)"')"
  [[ -n "$totals" ]] || return 1
  used="$(kubectl --kubeconfig "$kcfg" --request-timeout="$TIMEOUT" top nodes --no-headers 2>/dev/null | awk '
    { c=$2; if (c ~ /m$/) { sub(/m$/,"",c); c=c/1000 } cpu+=c;
      m=$4; n=m+0; u=m; sub(/^[0-9.]+/,"",u); mult=1;
      if(u=="Ki")mult=1024; else if(u=="Mi")mult=1048576;
      else if(u=="Gi")mult=1073741824; else if(u=="Ti")mult=1099511627776;
      mem+=n*mult }
    END{ printf "%.3f %.0f", cpu+0, mem+0 }')"
  [[ -n "$used" && "$used" != "0.000 0" ]] || ht=0
  printf '%s %s %s' "$totals" "${used:-0 0}" "$ht" | awk '{
    G=1073741824;
    if ($6=="1")
      printf "nodes %d · CPU %.1f/%.0f (%.0f%%) · RAM %.0f/%.0fGi (%.0f%%)",
        $1, $4, $2, ($2>0?$4/$2*100:0), $5/G, $3/G, ($3>0?$5/$3*100:0);
    else
      printf "nodes %d · CPU %.0f / RAM %.0fGi (allocatable; metrics-server недоступен)",
        $1, $2, $3/G;
  }'
}

cmd_nodescan() { _nodescan > "$NODEFILE" 2>/dev/null || true; }

cmd_ns_header() {
  local kcfg n; kcfg="$(get_kcfg)"; [[ -n "$kcfg" ]] && kcfg="$(basename "$kcfg")" || kcfg='—'
  n="$(_kcfg_paths | grep -c . || true)"
  if [[ "${n:-0}" -gt 1 ]]; then
    printf 'kubeconfig: %s%s%s   %s←/→ сменить файл%s\n' "$C_BOLD" "$kcfg" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '%snamespace · Enter — открыть · Esc — назад%s' "$C_DIM" "$C_RESET"
  else
    printf 'kubeconfig: %s%s%s\n' "$C_BOLD" "$kcfg" "$C_RESET"
    printf '%snamespace · Enter — открыть · Esc — выход%s' "$C_DIM" "$C_RESET"
  fi
}

cmd_main_header() {
  local cur i out=''; cur="$(get_kind)"
  for i in "${KINDS[@]}"; do
    if [[ "$i" == "$cur" ]]; then
      out+="${C_REV}${C_BOLD}${C_CYN} ${i} ${C_RESET}  "
    else
      out+="${C_DIM}${i}${C_RESET}  "
    fi
  done
  printf '%s\n' "$out"
  printf '%s←/→ вид · ↑/↓ ресурсы · Enter — shell в под · Ctrl-O — describe+logs · Ctrl-G — follow · Ctrl-R — обновить · Esc — назад%s' \
    "$C_DIM" "$C_RESET"
}

cmd_list_label() { printf ' %s @ %s ' "$(get_kind)" "$(get_ns)"; }

# ==========================================================================
#  PREVIEWS
# ==========================================================================
cmd_kcfg_preview() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" ]] || { echo '—'; return 0; }
  printf '%s%s%s\n\n' "$C_BOLD" "$f" "$C_RESET"
  kubectl --kubeconfig "$f" config get-contexts 2>&1
  printf '\n%s── cluster-info ──%s\n' "$C_DIM" "$C_RESET"
  kubectl --kubeconfig "$f" --request-timeout=4s cluster-info 2>&1 | head -4
}

cmd_ns_preview() {
  local ns="${1:-}"
  case "$ns" in ''|'!'|'?') echo '—'; return 0 ;; esac
  printf '%s%s%s\n\n' "$C_BOLD$C_CYN" "$ns" "$C_RESET"
  printf '  pods         %s\n' "$(kc get pods        -n "$ns" --no-headers 2>/dev/null | grep -c . || echo 0)"
  printf '  deployments  %s\n' "$(kc get deployments -n "$ns" --no-headers 2>/dev/null | grep -c . || echo 0)"
  printf '  services     %s\n' "$(kc get services    -n "$ns" --no-headers 2>/dev/null | grep -c . || echo 0)"
}

cmd_preview() {
  local kind="${1:-}" name="${2:-}" ns; ns="$(get_ns)"
  [[ -n "$name" && "$name" != ' ' ]] || { echo 'нет выбора'; return 0; }
  case "$kind" in
    pods)        _prev_pod "$ns" "$name" ;;
    deployments) _prev_describe deployment "$ns" "$name" ;;
    services)    _prev_describe service    "$ns" "$name" ;;
    *)           echo '—' ;;
  esac
}

_prev_pod() {
  local ns="$1" p="$2"
  printf '%s%s%s\n' "$C_BOLD$C_CYN" "$p" "$C_RESET"
  kc get pod -n "$ns" "$p" -o json 2>/dev/null | jq -r '
    "  node:       " + (.spec.nodeName // "-"),
    "  ip:         " + (.status.podIP  // "-"),
    "  phase:      " + (.status.phase  // "-"),
    "  containers: " + ([.spec.containers[].name] | join(", "))' 2>/dev/null
  printf '\n%s── logs (--tail=200, все контейнеры) ──%s\n' "$C_DIM" "$C_RESET"
  kc logs -n "$ns" "$p" --tail=200 --all-containers --prefix --timestamps 2>&1 | tail -n 400
  printf '\n%s── events ──%s\n' "$C_DIM" "$C_RESET"
  kc describe pod -n "$ns" "$p" 2>/dev/null | awk '/^Events:/{f=1} f' | tail -n 20
}

_prev_describe() {
  printf '%s%s/%s%s\n\n' "$C_BOLD$C_CYN" "$1" "$3" "$C_RESET"
  kc describe "$1" -n "$2" "$3" 2>&1
}

# ==========================================================================
#  FULL VIEW / FOLLOW
# ==========================================================================
cmd_full() {
  local kind="${1:-}" name="${2:-}" ns; ns="$(get_ns)"
  [[ -n "$name" ]] || { echo 'нет выбора'; return 0; }
  case "$kind" in
    pods)
      kc describe pod -n "$ns" "$name" 2>&1
      printf '\n\n===== logs (--tail=3000, все контейнеры) =====\n\n'
      kc logs -n "$ns" "$name" --tail=3000 --all-containers --prefix --timestamps 2>&1 ;;
    deployments) kc describe deployment -n "$ns" "$name" 2>&1 ;;
    services)    kc describe service    -n "$ns" "$name" 2>&1 ;;
    *) echo '—' ;;
  esac
}

cmd_follow() {
  local ns kind; ns="$(get_ns)"; kind="$(get_kind)"
  if [[ "$kind" != pods ]]; then echo 'follow логов доступен только для pods'; sleep 1; return 0; fi
  [[ -n "${1:-}" ]] || { echo 'нет пода'; return 0; }
  exec kubectl --kubeconfig "$(get_kcfg)" logs -n "$ns" -f --tail=200 --all-containers --prefix "$1" 2>&1
}

# Enter: pod → shell, остальное → describe в pager
cmd_enter() {
  local kind="${1:-}" name="${2:-}"
  [[ -n "$name" ]] || { echo 'нет выбора'; sleep 1; return 0; }
  case "$kind" in
    pods) cmd_shell "$name" ;;
    *)    cmd_full "$kind" "$name" | less -R ;;
  esac
}

cmd_shell() {
  local pod="${1:-}" ns kcfg; ns="$(get_ns)"; kcfg="$(get_kcfg)"
  [[ -n "$pod" ]] || { echo 'нет пода'; sleep 1; return 0; }
  local cs c=() ; mapfile -t cs < <(kubectl --kubeconfig "$kcfg" --request-timeout="$TIMEOUT" \
      get pod -n "$ns" "$pod" -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null)
  local con=''
  if   [[ ${#cs[@]} -gt 1 ]]; then
    con="$(printf '%s\n' "${cs[@]}" | "${FZF:-fzf}" --height=40% --layout=reverse --border=rounded \
            --prompt="контейнер в $pod ▸ " --header='выбор контейнера · Esc — отмена')" || return 0
  elif [[ ${#cs[@]} -eq 1 ]]; then
    con="${cs[0]}"
  fi
  [[ -n "$con" ]] && c=(-c "$con")
  local sh found=''
  for sh in /bin/bash /bin/sh /busybox/sh bash sh; do
    if kubectl --kubeconfig "$kcfg" --request-timeout="$TIMEOUT" \
         exec -n "$ns" "$pod" "${c[@]}" -- "$sh" -c 'exit 0' >/dev/null 2>&1; then
      found="$sh"; break
    fi
  done
  if [[ -z "$found" ]]; then
    printf '%sshell недоступен: под не запущен либо в образе нет bash/sh (distroless)%s\n' \
      "$C_RED" "$C_RESET"; sleep 2; return 0
  fi
  printf '%s→ exec %s%s%s  (%s)   Ctrl-D / exit — выйти%s\n\n' \
    "$C_DIM" "$C_BOLD" "$pod${con:+/$con}" "$C_RESET$C_DIM" "$found" "$C_RESET"
  kubectl --kubeconfig "$kcfg" exec -it -n "$ns" "$pod" "${c[@]}" -- "$found" || true
}

# ==========================================================================
#  KCFG / KIND cycling (←/→)
# ==========================================================================
cmd_kcfg_cycle() {
  local dir="${1:-1}" cur i n; cur="$(get_kcfg)"
  local files; mapfile -t files < <(_kcfg_paths)
  n=${#files[@]}; ((n)) || return 0
  i=0
  for i in "${!files[@]}"; do [[ "${files[$i]}" == "$cur" ]] && break; done
  i=$(( (i + dir + n) % n ))
  printf '%s' "${files[$i]}" > "$KCFGFILE"
  : > "$NSFILE"; rm -f "$NODEFILE"
}

cmd_kind_cycle() {
  local dir="${1:-1}" cur i n=${#KINDS[@]}; cur="$(get_kind)"
  i=0
  for i in "${!KINDS[@]}"; do [[ "${KINDS[$i]}" == "$cur" ]] && break; done
  i=$(( (i + dir + n) % n ))
  printf '%s' "${KINDS[$i]}" > "$KINDFILE"
}

# ==========================================================================
#  SCREENS
# ==========================================================================
FZF_COMMON=(--ansi --delimiter=$'\t' --layout=reverse --no-mouse --cycle
            --header-first --border=rounded --pointer='▶'
            --preview-window='right,58%,wrap,border-rounded')

# ---- fzf: поиск/установка ---------------------------------------------------
_fzf_ver_ok() {   # $1 — путь/имя fzf; ок, если это fzf и major>0 или minor>=FZF_MIN_MINOR
  local v; v="$("$1" --version 2>/dev/null | head -1)" || true
  [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+ ]] || return 1
  (( BASH_REMATCH[1] > 0 || BASH_REMATCH[2] >= FZF_MIN_MINOR ))
}

_download_fzf() {   # тянет последний релиз fzf в $LOCAL_BIN/fzf
  local arch os dl url dest="$LOCAL_BIN/fzf"
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l)        arch=armv7 ;;
    armv6l)        arch=armv6 ;;
    *) echo "неизвестная архитектура $(uname -m); поставьте fzf вручную" >&2; return 1 ;;
  esac
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  if   command -v curl >/dev/null; then dl=(curl -fsSL)
  elif command -v wget >/dev/null; then dl=(wget -qO-)
  else echo "нужен curl или wget" >&2; return 1; fi
  command -v tar >/dev/null || { echo "нужен tar" >&2; return 1; }
  echo "ищу последний релиз fzf…" >&2
  url="$("${dl[@]}" https://api.github.com/repos/junegunn/fzf/releases/latest \
        | grep -oE "https://[^\"]+/fzf-[0-9.]+-${os}_${arch}\.tar\.gz" | head -1)" || true
  [[ -n "$url" ]] || { echo "не нашёл бинарь fzf для ${os}_${arch} в релизах" >&2; return 1; }
  mkdir -p "$LOCAL_BIN"
  echo "качаю $url" >&2
  "${dl[@]}" "$url" | tar xzf - -C "$LOCAL_BIN" fzf || return 1
  chmod +x "$dest"
  echo "установлен $dest" >&2
}

# резолвит рабочий fzf в $FZF (и экспортит для дочерних вызовов); иначе die
_ensure_fzf() {
  if [[ -n "$FZF" ]]; then
    _fzf_ver_ok "$FZF" || die "KUBEVIEW_FZF=$FZF — не fzf или версия < 0.$FZF_MIN_MINOR"
  elif command -v fzf >/dev/null && _fzf_ver_ok fzf; then
    FZF=fzf
  elif [[ -x "$LOCAL_BIN/fzf" ]] && _fzf_ver_ok "$LOCAL_BIN/fzf"; then
    FZF="$LOCAL_BIN/fzf"
  else
    local have; have="$(fzf --version 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$have" ]]; then
      printf 'fzf %s — слишком старый (нужен >= 0.%s).\n' "$have" "$FZF_MIN_MINOR" >&2
    else
      printf 'fzf не найден (нужен >= 0.%s).\n' "$FZF_MIN_MINOR" >&2
    fi
    printf 'Скачать последний fzf в %s? [y/N] ' "$LOCAL_BIN" >&2
    local ans=''; read -r ans </dev/tty 2>/dev/null || true
    case "$ans" in
      y|Y|yes|Yes|да|Да)
        _download_fzf && _fzf_ver_ok "$LOCAL_BIN/fzf" \
          || die "автоустановка не удалась. Вручную:
  git clone --depth 1 https://github.com/junegunn/fzf ~/.fzf && ~/.fzf/install --bin"
        FZF="$LOCAL_BIN/fzf"
        case ":$PATH:" in *":$LOCAL_BIN:"*) :;; *)
          printf '\nдобавьте в ~/.bashrc:  export PATH="%s:$PATH"\n\n' "$LOCAL_BIN" >&2;; esac ;;
      *)
        die "нужен fzf >= 0.$FZF_MIN_MINOR (в apt Ubuntu он старый). Вручную:
  git clone --depth 1 https://github.com/junegunn/fzf ~/.fzf && ~/.fzf/install --bin
  export PATH=\"\$HOME/.fzf/bin:\$PATH\"" ;;
    esac
  fi
  export KUBEVIEW_FZF="$FZF"
}

# fzf: rc 0 — выбор, 1 — нет совпадений, 130 — Esc/Ctrl-C, 2 — ошибка (старая версия)
_fzf_die_if_broken() {
  [[ "$1" == 2 || "$1" == 127 ]] || return 0
  die "fzf завершился с ошибкой (rc=$1).
Обычно это старая версия fzf (нужен >= 0.$FZF_MIN_MINOR) — запустите скрипт ещё раз,
он предложит скачать свежий. Либо вручную:
  git clone --depth 1 https://github.com/junegunn/fzf ~/.fzf && ~/.fzf/install --bin
Если fzf свежий — проверьте, что терминал интерактивный (не pipe/cron)."
}

screen_kcfg() {
  local sel rc=0
  sel="$(cmd_kcfg_list | "$FZF" "${FZF_COMMON[@]}" \
        --with-nth='2..' \
        --border-label=' kubeview · выбор kubeconfig ' \
        --prompt='kubeconfig ▸ ' \
        --header=$'←/→ ↑/↓ — выбор · Enter — открыть · Esc — выход' \
        --preview="\"$SELF\" --kcfg-preview {1}")" || rc=$?
  _fzf_die_if_broken "$rc"
  [[ $rc -eq 0 && -n "$sel" ]] || return 1
  printf '%s' "${sel%%$'\t'*}" > "$KCFGFILE"
  : > "$NSFILE"; printf 'pods' > "$KINDFILE"; rm -f "$NODEFILE"
}

screen_ns() {
  local sel rc=0
  sel="$(cmd_ns_list | "$FZF" "${FZF_COMMON[@]}" \
        --with-nth='2..' \
        --border-label="$(cmd_crumb)" --border-label-pos='2:bottom' \
        --prompt='namespace ▸ ' \
        --header="$(cmd_ns_header)" \
        --preview="\"$SELF\" --ns-preview {1}" \
        --bind="left:execute-silent(\"$SELF\" --kcfg-cycle -1)+reload(\"$SELF\" --ns-list)+transform-border-label(\"$SELF\" --crumb)+transform-header(\"$SELF\" --ns-header)+first" \
        --bind="right:execute-silent(\"$SELF\" --kcfg-cycle 1)+reload(\"$SELF\" --ns-list)+transform-border-label(\"$SELF\" --crumb)+transform-header(\"$SELF\" --ns-header)+first" \
        --bind="ctrl-r:execute-silent(\"$SELF\" --nodescan)+reload(\"$SELF\" --ns-list)+transform-border-label(\"$SELF\" --crumb)")" || rc=$?
  _fzf_die_if_broken "$rc"
  [[ $rc -eq 0 && -n "$sel" ]] || return 1
  case "${sel%%$'\t'*}" in '!'|'?'|'') return 1 ;; esac
  printf '%s' "${sel%%$'\t'*}" > "$NSFILE"
}

screen_main() {
  local rc=0
  cmd_res_list | "$FZF" "${FZF_COMMON[@]}" \
    --with-nth='3..' \
    --border-label="$(cmd_crumb)" --border-label-pos='2:bottom' \
    --prompt='▸ ' \
    --header="$(cmd_main_header)" \
    --list-border=rounded --list-label="$(cmd_list_label)" \
    --preview="\"$SELF\" --preview {1} {2}" \
    --preview-label=' logs / describe ' \
    --bind="left:execute-silent(\"$SELF\" --kind-cycle -1)+reload(\"$SELF\" --res-list)+transform-header(\"$SELF\" --main-header)+transform-list-label(\"$SELF\" --list-label)+first" \
    --bind="right:execute-silent(\"$SELF\" --kind-cycle 1)+reload(\"$SELF\" --res-list)+transform-header(\"$SELF\" --main-header)+transform-list-label(\"$SELF\" --list-label)+first" \
    --bind="ctrl-r:execute-silent(\"$SELF\" --nodescan)+reload(\"$SELF\" --res-list)+transform-list-label(\"$SELF\" --list-label)+transform-border-label(\"$SELF\" --crumb)" \
    --bind="enter:execute(\"$SELF\" --enter {1} {2})" \
    --bind="ctrl-o:execute(\"$SELF\" --full {1} {2} | less -R)" \
    --bind="ctrl-g:execute(\"$SELF\" --follow {2} | less -R +F)" \
    || rc=$?
  _fzf_die_if_broken "$rc"
}

run() {
  command -v kubectl >/dev/null || die "kubectl не найден"
  command -v jq      >/dev/null || die "jq не найден (apt install jq / pacman -S jq)"
  _ensure_fzf

  local paths; mapfile -t paths < <(_kcfg_paths)
  [[ ${#paths[@]} -gt 0 ]] || die "в $KUBE_DIR нет kubeconfig-файлов (задайте KUBEVIEW_DIR=…)"
  : > "$NSFILE"; printf 'pods' > "$KINDFILE"

  # единственный kubeconfig — экран выбора файла пропускаем,
  # Esc из namespace тогда сразу выходит из программы
  if [[ ${#paths[@]} -eq 1 ]]; then
    printf '%s' "${paths[0]}" > "$KCFGFILE"
    while :; do
      screen_ns || { clear 2>/dev/null || true; exit 0; }
      screen_main
    done
  fi

  while :; do
    screen_kcfg || { clear 2>/dev/null || true; exit 0; }
    while :; do
      screen_ns || break
      screen_main
    done
  done
}

# ==========================================================================
case "${1:-}" in
  --kcfg-list)     cmd_kcfg_list ;;
  --kcfg-preview)  shift; cmd_kcfg_preview "${1:-}" ;;
  --kcfg-cycle)    shift; cmd_kcfg_cycle "${1:-1}" ;;
  --ns-list)       cmd_ns_list ;;
  --ns-preview)    shift; cmd_ns_preview "${1:-}" ;;
  --ns-header)     cmd_ns_header ;;
  --res-list)      cmd_res_list ;;
  --crumb)         cmd_crumb ;;
  --main-header)   cmd_main_header ;;
  --list-label)    cmd_list_label ;;
  --kind-cycle)    shift; cmd_kind_cycle "${1:-1}" ;;
  --preview)       shift; cmd_preview "${1:-}" "${2:-}" ;;
  --full)          shift; cmd_full "${1:-}" "${2:-}" ;;
  --enter)         shift; cmd_enter "${1:-}" "${2:-}" ;;
  --shell)         shift; cmd_shell "${1:-}" ;;
  --follow)        shift; cmd_follow "${1:-}" ;;
  --nodescan)      cmd_nodescan ;;
  --install-fzf)   _download_fzf && _fzf_ver_ok "$LOCAL_BIN/fzf" \
                     && echo "ok: $("$LOCAL_BIN/fzf" --version)" || die "не удалось" ;;
  -h|--help)       awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$SELF" ;;
  '')              run ;;
  *)               die "неизвестный аргумент: $1 (см. --help)" ;;
esac
