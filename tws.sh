#!/bin/sh
# workspace.sh - Manage a tmux workspace from a simple YAML file
#
# Usage:
#   workspace.sh [-L socket-name] [command] [args]
#
# Commands:
#   (default)   Up: if server absent, create sessions/windows from YAML; else attach
#   restart     Kill current server and recreate from YAML, then attach
#   kill        Kill everything in the current server and the server itself
#   snapshot [path]
#               Write current tmux layout to YAML (default: ~/.config/tmux/workspace.yaml)
#               Always create a workspace.backup.yaml next to the target first
#   ls          List current sessions and windows (with directories)
#   diff        Show diff between YAML and current server windows:
#                 - red minus (-): in YAML but not in server
#                 + green plus (+): in server but not in YAML
#
# YAML format (simple):
#   session:
#     window_name: /absolute/or/~path
#
# POSIX sh compliant; requires: tmux, awk, sed, sort, comm

set -eu

CONFIG_DIR="${HOME}/.config/tmux"
YAML_PATH="${CONFIG_DIR}/workspace.yaml"
TMUX_SOCKET=""
TMUX_ARGS=""

usage() {
	printf '%s\n' "Usage: $0 [-L socket-name] [restart|kill|snapshot [yaml_path]|ls|diff]" >&2
	exit 2
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

server_exists() {
	# Returns 0 if a tmux server is reachable on the selected socket
	tmux ${TMUX_ARGS} list-sessions >/dev/null 2>&1
}

attach_tmux() {
	# Attach to the first session; if none, just attach (tmux will error) so guard caller
	tmux ${TMUX_ARGS} attach-session || return 1
}

sorted_sessions() {
	tmux ${TMUX_ARGS} list-sessions -F '#{session_created} #{session_name}' | sort -n | awk '{print $2}' 2>/dev/null
}

attach_first() {
	first_session=$(sorted_sessions | head -n 1)
	if [ -n "$first_session" ]; then
		tmux ${TMUX_ARGS} attach-session -t "$first_session" || return 1
	else
		tmux ${TMUX_ARGS} attach-session || return 1
	fi
}

kill_server() {
	tmux ${TMUX_ARGS} kill-server >/dev/null 2>&1 || true
}

mkdir_p() {
	[ -d "$1" ] || mkdir -p "$1"
}

tilde_path() {
	# Replace leading $HOME with ~ for compact YAML
	case "$1" in
	"${HOME}" | "${HOME}/"*) printf '%s\n' "~${1#${HOME}}" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

expand_tilde() {
	case $1 in
	~) printf '%s\n' "$HOME" ;;
	~*) printf "$HOME%s\n" "${1#?}" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

parse_yaml() {
	# Parse simple YAML (session -> windows map). Emits lines:
	#   S|session
	#   W|session|window|dir
	# Only handles the simple structure used here.
	# shellcheck disable=SC2016
	awk '
    function rtrim(s){ sub(/[\t ]+$/,"",s); return s }
    function ltrim(s){ sub(/^[\t ]+/,"",s); return s }
    BEGIN { session = "" }
    {
      line = $0
      gsub(/\r/, "", line)
      # Strip comments (simple: # ... at end or full line)
      sub(/[\t ]+#.*$/, "", line)
      line = rtrim(line)
      if (line == "") next
      # Top-level session: ^name:$ (no leading spaces)
      if (line ~ /^[A-Za-z0-9_-]+:$/) {
        session = substr(line, 1, length(line)-1)
        printf("S|%s\n", session)
        next
      }
      # Indented window mapping: ^  key: value
      if (line ~ /^[\t ]+[A-Za-z0-9_-]+:[\t ]*.*$/) {
        indented = line
        key = indented
        sub(/^[\t ]+/, "", key)
        # split on first ':'
        idx = index(key, ":")
        if (idx == 0) next
        wname = substr(key, 1, idx-1)
        dir   = ltrim(substr(key, idx+1))
        if (session != "" && wname != "") {
          printf("W|%s|%s|%s\n", session, wname, dir)
        }
      }
    }
  ' "$1"
}

create_from_yaml() {
	file="$1"
	[ -r "$file" ] || {
		printf '%s\n' "Error: YAML not readable: $file" >&2
		exit 1
	}

	# Pre-scan YAML to collect unique sessions (order preserved)
	sessions_tmp="${CONFIG_DIR}/.sessions.$$"
	mkdir_p "${CONFIG_DIR}"
	parse_yaml "$file" | awk -F'|' '$1=="S"{if(!seen[$2]++){print $2}}' >"$sessions_tmp"
	total_sessions=$(wc -l <"$sessions_tmp" | awk '{print $1}')

	current_session=""
	created_count=0
	last_created_sec=""

	# Create sessions and windows as described
	parse_yaml "$file" | while IFS='|' read -r typ s w d; do
		case "$typ" in
		S)
			current_session="$s"
			# Only consider timing if the session does not already exist
			if ! tmux ${TMUX_ARGS} has-session -t "$current_session" >/dev/null 2>&1; then
				created_count=$((created_count + 1))
				# Skip any wait after the last session
				if [ "$created_count" -lt "$total_sessions" ]; then
					# If we created a previous session within the same unix second, wait until the second ticks
					if [ -n "$last_created_sec" ]; then
						now_sec=$(date +%s)
						if [ "$now_sec" -eq "$last_created_sec" ]; then
							# Busy-wait with tiny sleeps until the unix second changes; keep it minimal
							while :; do
								now_sec=$(date +%s)
								[ "$now_sec" -ne "$last_created_sec" ] && break
								sleep 0.01
							done
						fi
					fi
				fi
				# Create detached session with a dummy window to ensure session exists
				tmux ${TMUX_ARGS} new-session -d -s "$current_session" -n __init__
				last_created_sec=$(date +%s)
			fi
			;;

		W)
			# Expand ~ in directory; allow empty dir (tmux will use default)
			dir="$(expand_tilde "$d")"
			if [ -n "$dir" ]; then
				tmux ${TMUX_ARGS} new-window -t "$s:" -n "$w" -c "$dir"
			else
				tmux ${TMUX_ARGS} new-window -t "$s:" -n "$w"
			fi
			;;
		esac
	done

	rm -f "$sessions_tmp"

	# Remove dummy window from all sessions if present
	tmux ${TMUX_ARGS} list-sessions -F '#S' 2>/dev/null | while IFS= read -r sess; do
		tmux ${TMUX_ARGS} list-windows -t "$sess" -F '#W' 2>/dev/null |
			awk '$0=="__init__"{print}' | while IFS= read -r _; do
			tmux ${TMUX_ARGS} kill-window -t "$sess:__init__" >/dev/null 2>&1 || true
		done
		# Switch to the second window, then the first one
		# if there are at least two windows
		tmux ${TMUX_ARGS} select-window -t "$sess:2" >/dev/null 2>&1 || true
		tmux ${TMUX_ARGS} select-window -t "$sess:1" >/dev/null 2>&1 || true
	done
}

snapshot_to_yaml() {
	out="$1"
	outdir=$(dirname "$out")
	mkdir_p "$outdir"

	# Backup existing YAML if present
	if [ -f "$out" ]; then
		cp -p -- "$out" "$outdir/workspace.backup.yaml" 2>/dev/null || cp -p "$out" "$outdir/workspace.backup.yaml"
	fi

	tmp="${out}.tmp.$$"
	: >"$tmp"

	sorted_sessions | while IFS= read -r sess; do
		[ -n "$sess" ] || continue
		printf '%s:\n' "$sess" >>"$tmp"
		tmux ${TMUX_ARGS} list-windows -t "$sess" -F '#W>#{pane_current_path}' 2>/dev/null | while IFS=">" read -r wname wdir; do
			[ -n "$wname" ] || continue
			# Normalize path (fallback to HOME when empty)
			if [ -z "$wdir" ]; then wdir="$HOME"; fi
			wdir_disp="$(tilde_path "$wdir")"
			printf '  %s: %s\n' "$wname" "$wdir_disp" >>"$tmp"
		done
		printf '\n' >>"$tmp"
	done

	mv "$tmp" "$out"
}

list_current() {
	if ! server_exists; then
		printf '%s\n' 'No tmux server running.'
		return 1
	fi
	for sess in $(sorted_sessions); do
		[ -n "$sess" ] || continue
		printf '%s:\n' "$sess"
		tmux ${TMUX_ARGS} list-windows -t "$sess" -F "#W>#{pane_current_path}" 2>/dev/null | while IFS=">" read -r wname wdir; do
			[ -n "$wname" ] || continue
			if [ -z "$wdir" ]; then wdir="$HOME"; fi
			wdir_disp="$(tilde_path "$wdir")"
			printf '  %s: %s\n' "$wname" "$wdir_disp"
		done
		printf '\n'
	done
}

yaml_pairs() {
	# Emit "session|window" pairs from YAML
	parse_yaml "$1" | awk -F'|' '$1=="W"{printf "%s|%s\n",$2,$3}'
}

current_pairs() {
	# Emit "session|window" pairs from current server
	if ! server_exists; then return 0; fi
	for sess in $(sorted_sessions); do
		[ -n "$sess" ] || continue
		tmux ${TMUX_ARGS} list-windows -t "$sess" -F '#W' 2>/dev/null | while IFS= read -r wname; do
			[ -n "$wname" ] || continue
			printf '%s|%s\n' "$sess" "$wname"
		done
	done
}

show_diff() {
	[ -r "$YAML_PATH" ] || {
		printf '%s\n' "Error: YAML not found: $YAML_PATH" >&2
		exit 1
	}

	RED='\033[31m'
	GREEN='\033[32m'
	YELLOW='\033[33m'
	RESET='\033[0m'

	# Collect YAML per-session ordered windows (name and dir)
	ytmp="${CONFIG_DIR}/.ydiff.$$"
	trap 'rm -f "$ytmp" "$ctmp"' EXIT INT HUP TERM
	parse_yaml "$YAML_PATH" | awk -F'|' '
    $1=="S"{s=$2; order[s]=order[s]"\n"; next}
    $1=="W"{printf "%s|%s|%s\n", $2, $3, ($4==""?"~":$4)}
  ' >"$ytmp"

	# Collect current per-session ordered windows by invoking list_current output format
	ctmp="${CONFIG_DIR}/.cdiff.$$"
	: >"$ctmp"
	if server_exists; then
		for sess in $(sorted_sessions); do
			[ -n "$sess" ] || continue
			tmux ${TMUX_ARGS} list-windows -t "$sess" -F '#W>#{pane_current_path}' 2>/dev/null | while IFS=">" read -r wname wdir; do
				[ -n "$wname" ] || continue
				[ -z "$wdir" ] && wdir="$HOME"
				wdir_disp="$(tilde_path "$wdir")"
				printf '%s|%s|%s\n' "$sess" "$wname" "$wdir_disp" >>"$ctmp"
			done
		done
	fi

	# Build session lists preserving order using awk and then emit diff according to rules
	awk -F'|' -v RED="$RED" -v GREEN="$GREEN" -v YELLOW="$YELLOW" -v RESET="$RESET" '
    function print_header(s){ if(!printed_header[s]){ printf "%s:\n", s; printed_header[s]=1 } }
    function print_line(color, w, d){ printf "%s  %s: %s%s\n", color, w, d, RESET }

    # Simple LIS to detect stable relative order among common windows
    function lis_build(seq_len,   i,j,k,low,high,mid,pos,widx){
      tails_len=0
      for(i=1;i<=seq_len;i++){
        pos=i; val=seq[i]
        low=1; high=tails_len
        while(low<=high){
          mid=int((low+high)/2)
          if(tails[mid] < val) low=mid+1; else high=mid-1
        }
        tails[low]=val; prev[i]= (low>1)? tails_idx[low-1] : 0; tails_idx[low]=i
        if(low>tails_len) tails_len=low
      }
      # reconstruct mask
      k=tails_idx[tails_len]
      for(i=1;i<=seq_len;i++) in_lis[i]=0
      while(k>0){ in_lis[k]=1; k=prev[k] }
    }

    BEGIN { }

    # Read YAML data first to preserve its order per session and record session order
    FNR==NR {
      s=$1; w=$2; d=$3; if(d=="") d="~";
      if(!(s in y_sessions)){ y_session_order[++yso]=s; y_sessions[s]=1 }
      y_count[s]++;
      y_w[s, y_count[s]]=w; y_d[s, w]=d; y_pos[s, w]=y_count[s]; y_has[s, w]=1;
      next
    }

    # Read current data preserving order per session and record order for sessions only in current
    {
      s=$1; w=$2; d=$3; if(d=="") d="~";
      c_count[s]++;
      c_w[s, c_count[s]]=w; c_d[s, w]=d; c_pos[s, w]=c_count[s]; c_has[s, w]=1;
      if(!(s in c_sessions)){ c_session_order[++cso]=s; c_sessions[s]=1 }
      next
    }

    END {
      # Session order: YAML order first, then any sessions present only in current in their order
      for (i=1;i<=yso;i++) session_order[++so]=y_session_order[i]
      for (i=1;i<=cso;i++){ s=c_session_order[i]; if(!(s in y_sessions)) session_order[++so]=s }

      for (i=1; i<=so; i++) {
        s=session_order[i]; any=0;
        yc=y_count[s]; if(yc=="") yc=0;
        cc=c_count[s]; if(cc=="") cc=0;

        # Build sequence of YAML positions for current windows existing in YAML
        seq_len=0
        for (k=1; k<=cc; k++) {
          w=c_w[s, k]; if (y_pos[s, w] > 0) { seq[++seq_len]=y_pos[s, w]; seq_w_index[seq_len]=k }
        }
        # Compute LIS over that sequence
        delete tails; delete prev; delete tails_idx; delete in_lis
        if (seq_len>0) lis_build(seq_len)
        # Mark which current-order windows are in LIS (i.e., stable relative order)
        delete stable_cidx
        if (seq_len>0) {
          p=0; for (k=1; k<=seq_len; k++) if (in_lis[k]) { stable_cidx[ seq_w_index[k] ]=1 }
        }

        # Pass 1: YAML order
        for (k=1; k<=yc; k++) {
          w=y_w[s, k]; dY=y_d[s, w];
          if (!c_has[s, w]) {
            if(!any){ print_header(s); any=1 }
            print_line(RED, w, dY);
          } else {
            cidx=c_pos[s, w]; dC=c_d[s, w];
            if (stable_cidx[cidx]) {
              if (dY==dC) {
                if(!any){ print_header(s); any=1 }
                print_line("", w, dY);
              } else {
                if(!any){ print_header(s); any=1 }
                print_line(YELLOW, w, dC);
              }
            } else {
              if(!any){ print_header(s); any=1 }
              print_line(RED, w, dY);
            }
          }
        }

        # Pass 2: Current order
        for (k=1; k<=cc; k++) {
          w=c_w[s, k]; dC=c_d[s, w];
          if (!y_has[s, w]) {
            if(!any){ print_header(s); any=1 }
            print_line(GREEN, w, dC);
          } else {
            if (!stable_cidx[k]) {
              if(!any){ print_header(s); any=1 }
              print_line(GREEN, w, dC);
            }
          }
        }
        if(any) printf "\n";
      }
    }
  ' "$ytmp" "$ctmp"
}

main() {
	command_exists tmux || {
		printf '%s\n' 'Error: tmux is required on PATH' >&2
		exit 127
	}

	# Parse options (POSIX)
	while getopts ":L:" opt; do
		case "$opt" in
		L)
			TMUX_SOCKET="$OPTARG"
			;;
		:) usage ;;
		\?) usage ;;
		esac
	done
	shift $((OPTIND - 1))

	if [ -n "$TMUX_SOCKET" ]; then
		TMUX_ARGS="-L $TMUX_SOCKET"
	fi

	cmd="${1-}"

	case "$cmd" in
	restart)
		# Restart: kill server then (re)create from YAML and attach
		kill_server
		[ -r "$YAML_PATH" ] || {
			printf '%s\n' "Error: YAML not found: $YAML_PATH" >&2
			exit 1
		}
		create_from_yaml "$YAML_PATH"
		attach_first
		;;
	x | exit | kill)
		kill_server
		;;
	snap | snapshot)
		shift 1 || true
		target="${1-}"
		if [ -z "$target" ]; then target="$YAML_PATH"; fi
		if ! server_exists; then
			printf '%s\n' 'Error: no tmux server running to snapshot' >&2
			exit 1
		fi
		snapshot_to_yaml "$target"
		;;
	ls)
		list_current || true
		;;
	diff)
		show_diff
		;;
	"" | up | attach)
		if server_exists; then
			attach_tmux || exit 1
		else
			[ -r "$YAML_PATH" ] || {
				printf '%s\n' "Error: YAML not found: $YAML_PATH" >&2
				exit 1
			}
			create_from_yaml "$YAML_PATH"
			attach_first
		fi
		;;
	*)
		usage
		;;
	esac
}

main "$@"
