#!/usr/bin/env bash
#
# dockview — terminal UI to browse Docker containers and images.
#
#   Top   : tab switcher (Containers / Images), ←/→ to switch.
#   Left  : scrollable list for the active tab (images sorted by size, desc).
#   Right : details for the item under the cursor.
#   Bottom: full-width status bar on the outer frame — up/total containers,
#           disk usage, images, volumes, log size, build cache.
#
# Keys:  ↑/↓ move · ←/→ switch tab · Del remove selected (with confirm)
#        Ctrl-R refresh list+stats · Ctrl-L rescan log size · Enter full inspect
#        Ctrl-G container logs · Esc/Ctrl-C quit
#
# Deps:  docker, fzf (>= 0.65). Log-size scan additionally uses a throwaway
#        alpine/busybox container (needs the docker socket, no sudo).
#
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
LOGCACHE="${TMPDIR:-/tmp}/dockview-logsize.$(id -u)"
MODEFILE="${TMPDIR:-/tmp}/dockview-mode.$(id -u)"
NO_LOGS=0

# text-window helper for confirm / message dialogs
DIALOG=""
if   command -v whiptail >/dev/null 2>&1; then DIALOG=whiptail
elif command -v dialog   >/dev/null 2>&1; then DIALOG=dialog
fi

# ---------------------------------------------------------------- colours ----
# On by default (output is consumed by fzf --ansi / less -R); honour NO_COLOR
# and the --help screen.
if [[ -n "${NO_COLOR:-}" || "${1:-}" == -h || "${1:-}" == --help ]]; then
	C_RESET=; C_DIM=; C_BOLD=; C_REV=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_MAG=; C_CYN=
else
	C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_REV=$'\033[7m'
	C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
	C_BLU=$'\033[34m'; C_MAG=$'\033[35m'; C_CYN=$'\033[36m'
fi

die() { printf '%s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- helpers -----
# bytes -> human readable
human() {
	local b=${1:-0}
	awk -v b="$b" 'BEGIN{
		if (b=="" || b=="n/a") { print "n/a"; exit }
		split("B KB MB GB TB PB", u, " ");
		i=1; while (b>=1024 && i<6) { b/=1024; i++ }
		printf (i==1 ? "%d %s\n" : "%.2f %s\n"), b, u[i]
	}'
}

# --------------------------------------------------------------- list --------
list_containers() {
	docker ps -a --no-trunc \
		--format '{{.ID}}\t{{.State}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' |
	while IFS=$'\t' read -r id state name image status; do
		local icon col
		[[ "$image" == sha256:* ]] && image="${image:7:19}…"
		case "$state" in
			running)     icon='●'; col=$C_GRN ;;
			paused)      icon='‖'; col=$C_YEL ;;
			restarting)  icon='↻'; col=$C_YEL ;;
			created)     icon='◌'; col=$C_BLU ;;
			exited|dead) icon='○'; col=$C_RED ;;
			*)           icon='?'; col=$C_DIM ;;
		esac
		printf 'C\t%s\t%s%s%s %s%-24s%s %s%s%s %s(%s)%s\n' \
			"$id" \
			"$col" "$icon" "$C_RESET" \
			"$C_BOLD" "$name" "$C_RESET" \
			"$C_CYN" "$image" "$C_RESET" \
			"$C_DIM" "$status" "$C_RESET"
	done
}

list_images() {
	# largest first: convert docker's human size to bytes, sort desc, drop the key
	docker images --no-trunc \
		--format '{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' \
	| awk -F'\t' '{
		n=$4+0; u=$4; sub(/^[0-9.]+/,"",u); m=1
		if(u=="kB"||u=="KB")m=1e3; else if(u=="MB")m=1e6
		else if(u=="GB")m=1e9; else if(u=="TB")m=1e12
		printf "%018d\t%s\n", n*m, $0
	}' \
	| sort -rn \
	| cut -f2- \
	| while IFS=$'\t' read -r id repo tag size created; do
		local name="$repo:$tag" col=$C_MAG
		[[ "$repo" == "<none>" ]] && { name='<none>:<none> (dangling)'; col=$C_DIM; }
		printf 'I\t%s\t%s◆%s %s%s%s  %s%s%s  %s· %s ago%s\n' \
			"$id" \
			"$col" "$C_RESET" \
			"$col" "$name" "$C_RESET" \
			"$C_BOLD$C_YEL" "$size" "$C_RESET" \
			"$C_DIM" "$created" "$C_RESET"
	done
}

get_mode() { cat "$MODEFILE" 2>/dev/null || echo containers; }

cmd_setmode() {
	case "${1:-}" in
		images|containers) printf '%s' "$1" >"$MODEFILE" ;;
	esac
}

cmd_togglemode() {
	[[ "$(get_mode)" == images ]] && cmd_setmode containers || cmd_setmode images
}

cmd_list() {
	local mode="${1:-$(get_mode)}"
	case "$mode" in
		images) list_images ;;
		*)      list_containers ;;
	esac
}

# tab bar rendered into the fzf --header
cmd_tabs() {
	local mode c i
	mode="$(get_mode)"
	if [[ "$mode" == images ]]; then
		c="${C_DIM}  Containers  ${C_RESET}"
		i="${C_REV}${C_BOLD}${C_MAG}  Images  ${C_RESET}"
	else
		c="${C_REV}${C_BOLD}${C_CYN}  Containers  ${C_RESET}"
		i="${C_DIM}  Images  ${C_RESET}"
	fi
	printf '%s %s   %s◂ ▸ switch tab%s\n' "$c" "$i" "$C_DIM" "$C_RESET"
	printf '%s←/→%s tab · %sDel%s remove · %sCtrl-R%s refresh · %sCtrl-L%s logs · %sEnter%s inspect · %sCtrl-G%s logs\n' \
		"$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" \
		"$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
}

# --------------------------------------------------------------- preview ----
hr() { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────" "$C_RESET"; }
kv() { printf '%s%-14s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }

HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

preview_container() {
	local id="$1" j
	j="$(docker inspect "$id" 2>/dev/null || true)"
	if [[ -z "$j" || "$j" == "[]" ]]; then echo "no data for container $id"; return; fi

	if [[ $HAVE_JQ -eq 1 ]]; then
		local name image st running rc created started finished cmd ports mounts nets restart
		name=$(jq -r     '.[0].Name | sub("^/";"")'                           <<<"$j")
		image=$(jq -r    '.[0].Config.Image // "?"'                           <<<"$j")
		st=$(jq -r       '.[0].State.Status // "?"'                           <<<"$j")
		running=$(jq -r  '.[0].State.Running // false'                        <<<"$j")
		rc=$(jq -r       '.[0].RestartCount // 0'                             <<<"$j")
		created=$(jq -r  '(.[0].Created // "")[0:19]'                         <<<"$j")
		started=$(jq -r  '(.[0].State.StartedAt // "")[0:19]'                 <<<"$j")
		finished=$(jq -r '.[0].State.FinishedAt // ""'                        <<<"$j")
		cmd=$(jq -r      '([.[0].Path] + (.[0].Args // [])) | join(" ")'      <<<"$j")
		ports=$(jq -r    '.[0].NetworkSettings.Ports // {} | to_entries
		                  | map(.key + (if .value then " → " + .value[0].HostPort else "" end))
		                  | join(", ")'                                       <<<"$j")
		mounts=$(jq -r   '.[0].Mounts // [] | map(.Type + ":" + (.Name // .Source // "?")
		                  + " → " + .Destination) | join("   ")'              <<<"$j")
		nets=$(jq -r     '.[0].NetworkSettings.Networks // {} | to_entries
		                  | map(.key + (if (.value.IPAddress // "") != "" then " " + .value.IPAddress else "" end))
		                  | join(", ")' <<<"$j")
		restart=$(jq -r  '.[0].HostConfig.RestartPolicy.Name // ""'           <<<"$j")

		printf '%s%s%s\n' "$C_BOLD$C_CYN" "$name" "$C_RESET"; hr
		local scol=$C_GRN; [[ "$running" == "true" ]] || scol=$C_RED
		kv "State"     "${scol}${st}${C_RESET}"
		kv "Image"     "$image"
		kv "Command"   "${C_DIM}${cmd}${C_RESET}"
		kv "Created"   "$created"
		kv "Started"   "$started"
		[[ "$running" != "true" && -n "$finished" && "$finished" != 0001-01-01T* ]] \
			&& kv "Finished" "${finished:0:19}"
		kv "Restarts"  "$rc  (${restart:-no policy})"
		kv "Ports"     "${ports:-—}"
		kv "Mounts"    "${mounts:-—}"
		kv "Networks"  "${nets:-—}"
	else
		printf '%s%s%s\n' "$C_BOLD$C_CYN" "$id" "$C_RESET"; hr
		docker inspect "$id" 2>/dev/null | head -80
	fi

	echo; printf '%sEnv%s\n' "$C_DIM" "$C_RESET"
	docker inspect "$id" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
		| sed 's/^/  /' | head -20
	echo; printf '%sLast log lines%s\n' "$C_DIM" "$C_RESET"
	docker logs --tail 15 --timestamps "$id" 2>&1 | sed 's/^/  /' || true
}

preview_image() {
	local id="$1" j
	j="$(docker image inspect "$id" 2>/dev/null || true)"
	if [[ -z "$j" || "$j" == "[]" ]]; then echo "no data for image $id"; return; fi

	if [[ $HAVE_JQ -eq 1 ]]; then
		local tags shaid created size platform layers workdir entry cmd
		tags=$(jq -r     '.[0].RepoTags // [] | if length>0 then join(", ") else "<untagged>" end' <<<"$j")
		shaid=$(jq -r    '.[0].Id // "" | sub("^sha256:";"")'                 <<<"$j")
		created=$(jq -r  '(.[0].Created // "")[0:19]'                         <<<"$j")
		size=$(jq -r     '.[0].Size // 0'                                     <<<"$j")
		platform=$(jq -r '"\(.[0].Os // "?")/\(.[0].Architecture // "?")"'    <<<"$j")
		layers=$(jq -r   '.[0].RootFS.Layers // [] | length'                  <<<"$j")
		workdir=$(jq -r  '.[0].Config.WorkingDir // "" | if . == "" then "—" else . end' <<<"$j")
		entry=$(jq -rc   '.[0].Config.Entrypoint // "—"'                      <<<"$j")
		cmd=$(jq -rc     '.[0].Config.Cmd // "—"'                             <<<"$j")

		printf '%s%s%s\n' "$C_BOLD$C_MAG" "$tags" "$C_RESET"; hr
		kv "ID"         "$shaid"
		kv "Created"    "$created"
		kv "Size"       "${C_BOLD}${C_YEL}$(human "$size")${C_RESET}"
		kv "Platform"   "$platform"
		kv "Layers"     "$layers"
		kv "WorkDir"    "$workdir"
		kv "Entrypoint" "$entry"
		kv "Cmd"        "$cmd"
	else
		printf '%s%s%s\n' "$C_BOLD$C_MAG" "$id" "$C_RESET"; hr
		docker image inspect "$id" 2>/dev/null | head -80
	fi

	echo; printf '%sEnv%s\n' "$C_DIM" "$C_RESET"
	docker image inspect "$id" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
		| sed 's/^/  /' | head -20
	echo; printf '%sHistory%s\n' "$C_DIM" "$C_RESET"
	docker history --no-trunc --format '{{.CreatedSince}}\t{{.Size}}\t{{.CreatedBy}}' "$id" 2>/dev/null \
		| awk -F'\t' '{c=$3; gsub(/\/bin\/sh -c #\(nop\) /,"",c); gsub(/\/bin\/sh -c /,"RUN ",c);
		              if(length(c)>90) c=substr(c,1,90)"…"; printf "  %-14s %-9s %s\n",$1,$2,c}' \
		| head -25
}

cmd_preview() {
	case "${1:-}" in
		C) preview_container "$2" ;;
		I) preview_image "$2" ;;
		*) echo "no selection" ;;
	esac
}

cmd_full() {
	case "${1:-}" in
		C) docker inspect "$2"; echo; docker logs --tail 200 --timestamps "$2" 2>&1 || true ;;
		I) docker image inspect "$2"; echo; docker history --no-trunc "$2" ;;
	esac
}

# --------------------------------------------------------------- dialogs ----
_strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

# fit a text-window height to its content (clamped)
_box_h() { local n=$1; ((n += 7)); ((n < 9)) && n=9; ((n > 22)) && n=22; echo "$n"; }

# can we open the controlling terminal?
_has_tty() { { true </dev/tty; } 2>/dev/null; }

# fallback: print lines centred on a cleared screen
_center_raw() {
	local rows cols top i line plain pad
	rows="$(tput lines 2>/dev/null || echo 24)"; cols="$(tput cols 2>/dev/null || echo 80)"
	clear
	top=$(( (rows - $#) / 2 )); ((top < 0)) && top=0
	for ((i = 0; i < top; i++)); do echo; done
	for line in "$@"; do
		plain="$(printf '%s' "$line" | _strip_ansi)"
		pad=$(( (cols - ${#plain}) / 2 )); ((pad < 0)) && pad=0
		printf '%*s%b\n' "$pad" '' "$line"
	done
}

# notify LINE...   — bordered message window, waits for OK
notify() {
	local msg; msg="$(printf '%s\n' "$@" | _strip_ansi)"
	if [[ -n "$DIALOG" ]] && _has_tty; then
		{ "$DIALOG" --title ' dockview ' --msgbox "$msg" "$(_box_h "$#")" 76 \
			</dev/tty >/dev/tty 2>&1; } || true
		return
	fi
	_center_raw "$@" "" "— press any key —"
	{ read -rsn1 _ </dev/tty; } 2>/dev/null || true
}

# confirm LINE...  — bordered Yes/No window; returns 0 on Yes
confirm() {
	local msg; msg="$(printf '%s\n' "$@" | _strip_ansi)"
	if [[ -n "$DIALOG" ]] && _has_tty; then
		local rc=0
		{ "$DIALOG" --title ' dockview ' --defaultno --yesno "$msg" \
			"$(_box_h "$#")" 76 </dev/tty >/dev/tty 2>&1; } || rc=$?
		return "$rc"
	fi
	_center_raw "$@" "" "[ y ] Yes      [ n ] No"
	local a=''
	{ read -rsn1 a </dev/tty; } 2>/dev/null || true
	[[ "$a" == y || "$a" == Y ]]
}

delete_container() {
	local id="$1" name state
	name="$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null || true)"; name="${name#/}"
	state="$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null || true)"
	[[ -z "$name" ]] && { notify "${C_RED}Container $id not found${C_RESET}"; return; }

	if [[ "$state" == running || "$state" == paused || "$state" == restarting ]]; then
		confirm "${C_YEL}Container${C_RESET} ${C_BOLD}$name${C_RESET} ${C_YEL}is $state.${C_RESET}" \
		        "Stop it and remove?" || return
		if docker rm -f "$id" >/tmp/dockview-del.$$ 2>&1; then
			notify "${C_GRN}Removed container${C_RESET} ${C_BOLD}$name${C_RESET}"
		else
			notify "${C_RED}Could not remove:${C_RESET}" "$(cat /tmp/dockview-del.$$)"
		fi
	else
		confirm "Remove container ${C_BOLD}$name${C_RESET} ${C_DIM}($state)${C_RESET}?" || return
		if docker rm "$id" >/tmp/dockview-del.$$ 2>&1; then
			notify "${C_GRN}Removed container${C_RESET} ${C_BOLD}$name${C_RESET}"
		else
			notify "${C_RED}Could not remove:${C_RESET}" "$(cat /tmp/dockview-del.$$)"
		fi
	fi
	rm -f /tmp/dockview-del.$$
}

delete_image() {
	local id="$1" tags full users
	tags="$(docker image inspect --format '{{join .RepoTags ", "}}' "$id" 2>/dev/null || true)"
	[[ -z "$tags" ]] && tags='<untagged>'
	full="$(docker image inspect --format '{{.Id}}' "$id" 2>/dev/null || true)"
	[[ -z "$full" ]] && { notify "${C_RED}Image $id not found${C_RESET}"; return; }

	# containers (any state) created from exactly this image
	users="$(docker ps -a --no-trunc --format '{{.ID}}' 2>/dev/null \
		| while read -r cid; do
			[[ -z "$cid" ]] && continue
			local info ciid cname cstate
			info="$(docker inspect --format '{{.Image}}|{{.Name}}|{{.State.Status}}' "$cid" 2>/dev/null || true)"
			IFS='|' read -r ciid cname cstate <<<"$info"
			[[ "$ciid" == "$full" ]] && printf '  • %s  (%s)\n' "${cname#/}" "$cstate"
		done || true)"

	if [[ -n "$users" ]]; then
		notify "${C_RED}Cannot remove image${C_RESET} ${C_BOLD}$tags${C_RESET}" \
		       "" \
		       "It is used by the following container(s):" \
		       "$users" \
		       "" \
		       "${C_DIM}remove those containers first${C_RESET}"
		return
	fi

	confirm "Remove image ${C_BOLD}$tags${C_RESET}?" || return
	if docker rmi "$id" >/tmp/dockview-del.$$ 2>&1; then
		notify "${C_GRN}Removed image${C_RESET} ${C_BOLD}$tags${C_RESET}"
	else
		notify "${C_RED}Could not remove image:${C_RESET}" "$(cat /tmp/dockview-del.$$)"
	fi
	rm -f /tmp/dockview-del.$$
}

cmd_delete() {
	case "${1:-}" in
		C) delete_container "$2" ;;
		I) delete_image "$2" ;;
	esac
}

# --------------------------------------------------------------- log size ---
pick_helper_image() {
	local i
	for i in alpine:latest busybox:latest alpine busybox; do
		docker image inspect "$i" >/dev/null 2>&1 && { echo "$i"; return; }
	done
	docker images --format '{{.Repository}}:{{.Tag}}' \
		| grep -m1 -E '^(alpine|busybox)(:|$)' && return
	echo alpine:latest   # will be pulled
}

cmd_logsize() {
	[[ $NO_LOGS -eq 1 ]] && { echo n/a >"$LOGCACHE"; return; }
	local root img
	root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" || root=/var/lib/docker
	img="$(pick_helper_image)"
	docker run --rm -v "$root:/host:ro" "$img" sh -c \
		'du -sbc /host/containers/*/*-json.log* 2>/dev/null | tail -1 | cut -f1' \
		2>/dev/null >"$LOGCACHE" || echo n/a >"$LOGCACHE"
	[[ -s "$LOGCACHE" ]] || echo n/a >"$LOGCACHE"
}

# ------------------------------------------------------------ status bar ----
# One line, rendered as the label on the *outer* border (bottom edge), so it
# spans the whole width — list + details — not just the list column.
cmd_status() {
	local df run tot
	df="$(docker system df --format '{{json .}}' 2>/dev/null)"
	run="$(docker ps -q 2>/dev/null | grep -c . || true)"
	tot="$(docker ps -aq 2>/dev/null | grep -c . || true)"

	# jq-free field pluck: val <Type> <Key>
	val() {
		printf '%s\n' "$df" | grep -F "\"Type\":\"$1\"" \
			| grep -oE "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
	}

	local cr_size im_count im_size im_recl vo_size bc_size logs
	cr_size="$(val Containers Size)"
	im_count="$(val Images TotalCount)"; im_size="$(val Images Size)"
	im_recl="$(val Images Reclaimable)"; im_recl="${im_recl%% *}"
	vo_size="$(val 'Local Volumes' Size)"
	bc_size="$(val 'Build Cache' Size)"
	logs="$(cat "$LOGCACHE" 2>/dev/null || echo n/a)"
	[[ "$logs" =~ ^[0-9]+$ ]] && logs="$(human "$logs")"

	printf ' cont %s/%s · %s  │  img %s · %s (−%s)  │  vol %s · log %s · cache %s ' \
		"${run:-0}" "${tot:-0}" "${cr_size:-?}" \
		"${im_count:-?}" "${im_size:-?}" "${im_recl:-?}" \
		"${vo_size:-?}" "${logs}" "${bc_size:-?}"
}

# --------------------------------------------------------------- main -------
main() {
	command -v docker >/dev/null || die "docker not found"
	command -v fzf   >/dev/null || die "fzf not found (install: pacman -S fzf)"
	docker info >/dev/null 2>&1 || die "cannot talk to docker daemon"

	if [[ $NO_LOGS -eq 0 ]]; then
		printf 'scanning container log sizes (one-off helper container)…\r' >&2
		cmd_logsize
	else
		echo n/a >"$LOGCACHE"
	fi
	printf containers >"$MODEFILE"   # every launch starts on the Containers tab

	local st_refresh="transform-border-label(\"$SELF\" --status)"
	cmd_list | fzf \
		--ansi --delimiter='\t' --with-nth='3..' \
		--layout=reverse --cycle --no-mouse --header-first \
		--border=rounded --border-label-pos='2:bottom' \
		--border-label="$(cmd_status)" \
		--margin=0 --padding=0 \
		--input-border=rounded --input-label=' filter ' \
		--header-border=rounded --header-label=' dockview ' \
		--list-border=rounded --list-label=' items ' \
		--prompt='▸ ' --pointer='▶' \
		--header="$(cmd_tabs)" \
		--preview="\"$SELF\" --preview {1} {2}" \
		--preview-window='right,58%,wrap,border-rounded' \
		--preview-label=' details ' \
		--bind="left:execute-silent(\"$SELF\" --setmode containers)+reload(\"$SELF\" --list)+transform-header(\"$SELF\" --tabs)+first" \
		--bind="right:execute-silent(\"$SELF\" --setmode images)+reload(\"$SELF\" --list)+transform-header(\"$SELF\" --tabs)+first" \
		--bind="shift-tab:execute-silent(\"$SELF\" --togglemode)+reload(\"$SELF\" --list)+transform-header(\"$SELF\" --tabs)+first" \
		--bind="tab:execute-silent(\"$SELF\" --togglemode)+reload(\"$SELF\" --list)+transform-header(\"$SELF\" --tabs)+first" \
		--bind="del:execute(\"$SELF\" --delete {1} {2})+reload(\"$SELF\" --list)+$st_refresh" \
		--bind="ctrl-r:reload(\"$SELF\" --list)+$st_refresh" \
		--bind="ctrl-l:execute(\"$SELF\" --logsize)+$st_refresh" \
		--bind="enter:execute(\"$SELF\" --full {1} {2} | less -R)" \
		--bind="ctrl-g:execute(docker logs --tail 500 -f {2} 2>&1 | less -R +G)" \
		|| true
}

# --------------------------------------------------------------- dispatch ---
case "${1:-}" in
	--list)       shift; cmd_list "${1:-}" ;;
	--setmode)    shift; cmd_setmode "${1:-}" ;;
	--togglemode) cmd_togglemode ;;
	--tabs)       cmd_tabs ;;
	--preview)    shift; cmd_preview "${1:-}" "${2:-}" ;;
	--full)       shift; cmd_full "${1:-}" "${2:-}" ;;
	--delete)     shift; cmd_delete "${1:-}" "${2:-}" ;;
	--status)     cmd_status ;;
	--logsize)    cmd_logsize ;;
	--no-logs)    NO_LOGS=1; main ;;
	-h|--help)    awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$SELF" ;;
	'')           main ;;
	*)            die "unknown option: $1 (try --help)" ;;
esac
