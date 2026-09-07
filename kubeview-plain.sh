#!/usr/bin/env bash
# kubeview-plain — то же, что kubeview.sh, но на dialog/whiptail (без fzf).
#   Меню: kubeconfig → namespace → вид (pods/deployments/services) → ресурс →
#   действие (логи / logs -f / describe / shell). Cancel/Esc — шаг назад,
#   из выбора kubeconfig — выход.
# Нет живого превью и fuzzy-поиска — зато dialog/whiptail есть почти везде.
#
#   KUBEVIEW_DIR=~/.kube   каталог с kubeconfig-файлами
#   KUBEVIEW_DEBUG=1       не запускать меню, только показать диагностику
set -uo pipefail

KUBE_DIR="${KUBEVIEW_DIR:-$HOME/.kube}"
TIMEOUT=8s
KCFG=""

# ---- аварийный выход с видимым сообщением (dialog чистит экран) --------------
fail() {
  trap - EXIT
  clear 2>/dev/null || true; stty sane 2>/dev/null || true
  printf '\n\033[1;31mkubeview-plain:\033[0m %s\n\n' "$*" >&2
  printf 'нажмите любую клавишу…' >&2
  read -rsn1 _ </dev/tty 2>/dev/null || true; echo >&2
  exit 1
}
trap 'rc=$?; if (( rc != 0 )); then
        stty sane 2>/dev/null || true
        printf "\n\033[1;31mkubeview-plain: неожиданный выход (код %s), строка %s\033[0m\n" \
          "$rc" "${BASH_LINENO[0]:-?}" >&2
        printf "нажмите любую клавишу…" >&2
        read -rsn1 _ </dev/tty 2>/dev/null || true; echo >&2
      fi' EXIT

# ---- выбор бэкенда + совместимые опции --------------------------------------
if   command -v dialog   >/dev/null 2>&1; then DIALOG=dialog;   CANCEL=(--cancel-label "Назад")
elif command -v whiptail >/dev/null 2>&1; then DIALOG=whiptail; CANCEL=(--cancel-button "Назад")
else fail "нужен dialog или whiptail:  sudo apt install dialog"; fi
command -v kubectl >/dev/null || fail "kubectl не найден"

kc() { kubectl --kubeconfig "$KCFG" --request-timeout="$TIMEOUT" "$@"; }

# menu "title" tag1 item1 tag2 item2 ...  -> печатает выбранный tag (rc!=0 = Назад/Esc)
menu() {
  local title="$1"; shift
  local n=$(( $# / 2 )) h
  h=$(( n + 8 )); (( h > 20 )) && h=20; (( h < 9 )) && h=9
  "$DIALOG" --title " kubeview " "${CANCEL[@]}" \
    --menu "$title" "$h" 76 "$n" "$@" 3>&1 1>&2 2>&3
}
msg() {
  local text="$1" h
  h=$(( $(printf '%s\n' "$text" | wc -l) + 7 ))
  (( h < 9 )) && h=9; (( h > 20 )) && h=20
  "$DIALOG" --title " kubeview " --msgbox "$text" "$h" 72
}

pager() { clear 2>/dev/null || true; { "$@"; } 2>&1 | less -R; }

kcfg_paths() {
  local f
  for f in "$KUBE_DIR"/*; do
    [[ -f "$f" ]] || continue
    grep -qE '^(apiVersion:|clusters:|current-context:|kind:[[:space:]]*Config)' "$f" 2>/dev/null \
      && printf '%s\n' "$f"
  done | sort
}

pick_kcfg() {
  local files; mapfile -t files < <(kcfg_paths)
  if (( ${#files[@]} == 0 )); then
    fail "в $KUBE_DIR нет распознанных kubeconfig-файлов.
содержимое каталога:
$(ls -a "$KUBE_DIR" 2>&1)
задайте другой каталог:  KUBEVIEW_DIR=/path ./kubeview-plain.sh"
  fi
  if (( ${#files[@]} == 1 )); then KCFG="${files[0]}"; return 0; fi
  local args=() f
  for f in "${files[@]}"; do
    args+=( "$f" "→ $(kubectl --kubeconfig "$f" config current-context 2>/dev/null || echo '?')" )
  done
  KCFG="$(menu "kubeconfig:" "${args[@]}")" || return 1
}

pick_ns() {
  local out rc
  out="$(kc get ns -o custom-columns=:.metadata.name --no-headers 2>&1)"; rc=$?
  if (( rc != 0 )) || [[ -z "$out" ]]; then
    msg "kubeconfig: $(basename "$KCFG")

не удалось получить список namespaces:

$out"
    return 1
  fi
  local args=() name
  while read -r name; do [[ -n "$name" ]] && args+=( "$name" "ns" ); done <<< "$out"
  menu "namespace  ($(basename "$KCFG")):" "${args[@]}"
}

pick_kind() {
  local ns="$1" p d s
  p=$(kc get pods        -n "$ns" --no-headers 2>/dev/null | grep -c . || true)
  d=$(kc get deployments -n "$ns" --no-headers 2>/dev/null | grep -c . || true)
  s=$(kc get services    -n "$ns" --no-headers 2>/dev/null | grep -c . || true)
  menu "namespace $ns — что смотрим:" \
    pods "поды (${p:-0})" deployments "деплойменты (${d:-0})" services "сервисы (${s:-0})"
}

pick_res() {
  local ns="$1" kind="$2" args=() name rest
  while read -r name rest; do
    [[ -n "$name" ]] && args+=( "$name" "${rest:-—}" )
  done < <(kc get "$kind" -n "$ns" --no-headers 2>/dev/null)
  if (( ${#args[@]} == 0 )); then
    msg "в namespace $ns нет ресурсов вида $kind"
    return 1
  fi
  menu "$kind @ $ns:" "${args[@]}"
}

pod_shell() {
  local ns="$1" pod="$2" c="" sh
  local cs; mapfile -t cs < <(kc get pod -n "$ns" "$pod" \
      -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null)
  if (( ${#cs[@]} > 1 )); then
    local a=() x; for x in "${cs[@]}"; do a+=( "$x" "container" ); done
    c="$(menu "контейнер в $pod:" "${a[@]}")" || return 0
  elif (( ${#cs[@]} == 1 )); then
    c="${cs[0]}"
  fi
  local cf=(); [[ -n "$c" ]] && cf=(-c "$c")
  clear 2>/dev/null || true
  for sh in /bin/bash /bin/sh /busybox/sh; do
    if kc exec -n "$ns" "$pod" ${cf[@]+"${cf[@]}"} -- "$sh" -c 'exit 0' >/dev/null 2>&1; then
      printf '→ exec %s  (%s)   Ctrl-D / exit — выйти\n\n' "${pod}${c:+/$c}" "$sh"
      kubectl --kubeconfig "$KCFG" exec -it -n "$ns" "$pod" ${cf[@]+"${cf[@]}"} -- "$sh" || true
      return 0
    fi
  done
  printf '\033[31mshell недоступен: под не запущен либо в образе нет bash/sh\033[0m\n'
  sleep 2
}

actions() {
  local ns="$1" kind="$2" res="$3" a
  while :; do
    if [[ "$kind" == pods ]]; then
      a="$(menu "$res:" \
            logs     "логи (--tail=2000)" \
            follow   "logs -f (следить)" \
            describe "kubectl describe" \
            shell    "shell в контейнере")" || return 0
    else
      a="$(menu "$res:" describe "kubectl describe")" || return 0
    fi
    case "$a" in
      logs)     pager kc logs -n "$ns" "$res" --tail=2000 --all-containers --prefix --timestamps ;;
      follow)   clear 2>/dev/null || true
                kubectl --kubeconfig "$KCFG" logs -n "$ns" -f --tail=200 \
                  --all-containers --prefix "$res" 2>&1 | less -R +F ;;
      describe) pager kc describe "$kind" -n "$ns" "$res" ;;
      shell)    pod_shell "$ns" "$res" ;;
      *)        : ;;
    esac
  done
}

diag() {
  echo "DIALOG   = $DIALOG ($("$DIALOG" --version 2>&1 | head -1))"
  echo "KUBE_DIR = $KUBE_DIR"
  echo "kubeconfig-файлы:"; kcfg_paths | sed 's/^/  /'
  local f
  while read -r f; do
    [[ -n "$f" ]] || continue
    printf '  %s -> ctx %s\n' "$(basename "$f")" \
      "$(kubectl --kubeconfig "$f" config current-context 2>/dev/null || echo '?')"
  done < <(kcfg_paths)
}

main() {
  local single=0
  [[ $(kcfg_paths | grep -c . || true) -eq 1 ]] && single=1
  while :; do
    pick_kcfg || { clear 2>/dev/null || true; trap - EXIT; exit 0; }
    while :; do
      ns="$(pick_ns)" || break
      while :; do
        kind="$(pick_kind "$ns")" || break
        while :; do
          res="$(pick_res "$ns" "$kind")" || break
          actions "$ns" "$kind" "$res"
        done
      done
    done
    (( single )) && { clear 2>/dev/null || true; trap - EXIT; exit 0; }
  done
}

case "${1:-}" in
  -h|--help) awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$0"; trap - EXIT ;;
  *)         [[ "${KUBEVIEW_DEBUG:-}" == 1 ]] && { diag; trap - EXIT; exit 0; }
             main ;;
esac
