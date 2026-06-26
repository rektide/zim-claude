_cyc_store() {
	[[ -n "$CLAUDE_CREDS_DIR$HOME" ]] || { print -u2 "cyc: neither CLAUDE_CREDS_DIR nor \$HOME is set — can't locate credential store"; return 1; }
	print -r -- "${CLAUDE_CREDS_DIR:-$HOME/.claude/creds}"
}
_cyc_creds() { print -r -- "$HOME/.claude/.credentials.json" }
_cyc_cfg() { print -r -- "$HOME/.claude.json" }

_cyc_current() {
	local rt f stored email
	rt=$(jq -r '.claudeAiOauth.refreshToken // empty' "$(_cyc_creds)" 2>/dev/null)
	if [[ -n "$rt" ]]; then
		for f in "$(_cyc_store)"/*.json(N); do
			stored=$(jq -r '.claudeAiOauth.refreshToken // empty' "$f" 2>/dev/null)
			[[ "$stored" == "$rt" ]] && { print -r -- "${${f:t}%.json}"; return; }
		done
	fi
	email=$(jq -r '.oauthAccount.emailAddress // empty' "$(_cyc_cfg)" 2>/dev/null) || return 0
	[[ -n "$email" ]] && print -r -- "${email%@*}"
}

# Identify the current account with explicit confidence level.
# Prints "<method>\t<handle>" on stdout. method is one of:
#   refresh-token  live refresh token matches a stored file (high confidence)
#   oauth-email    token match failed; oauthAccount.emailAddress local-part
#                  matches a stored file (lower confidence — cached identity,
#                  may be stale; this is the failure mode that corrupts stores)
#   none           can't identify: no refresh token, no email, or no stored
#                  file matches. Callers should refuse destructive ops.
# handle is the account name for refresh-token/oauth-email, empty for none.
_cyc_current_check() {
	local rt f stored email lp
	rt=$(jq -r '.claudeAiOauth.refreshToken // empty' "$(_cyc_creds)" 2>/dev/null)
	if [[ -n "$rt" ]]; then
		for f in "$(_cyc_store)"/*.json(N); do
			stored=$(jq -r '.claudeAiOauth.refreshToken // empty' "$f" 2>/dev/null)
			if [[ "$stored" == "$rt" ]]; then
				print -r -- "refresh-token	${${f:t}%.json}"
				return
			fi
		done
	fi
	email=$(jq -r '.oauthAccount.emailAddress // empty' "$(_cyc_cfg)" 2>/dev/null)
	[[ -n "$email" ]] && lp="${email%@*}"
	if [[ -n "$lp" && -f "$(_cyc_store)/$lp.json" ]]; then
		print -r -- "oauth-email	$lp"
		return
	fi
	print -r -- "none	"
}

_cyc_accounts() {
	local f
	local -a out=()
	[[ -d "$(_cyc_store)" ]] || return 0
	for f in "$(_cyc_store)"/*.json(N); do out+=("${${f:t}%.json}"); done
	print -rl -- "${(@on)out}"
}

_cyc_save_current() {
	local handle="$1" dest
	[[ -n "$handle" && -f "$(_cyc_creds)" ]] || return 1
	command mkdir -p "$(_cyc_store)"
	dest="$(_cyc_store)/$handle.json"
	typeset -g _cyc_save_changed=0
	[[ -f "$dest" ]] && ! command cmp -s "$dest" "$(_cyc_creds)" && _cyc_save_changed=1
	command cp "$(_cyc_creds)" "$dest"
	command chmod 600 "$dest"
}

_cyc_resolve() {
	local needle="$1" a lp
	local -a m=()
	shift
	lp="${needle%@*}"
	for a in "$@"; do
		if [[ "$a" == "$needle" || "$a" == "$lp" ]]; then
			print -r -- "$a"
			return
		fi
		[[ "$a" == "$lp"* ]] && m+=("$a")
	done
	(( ${#m[@]} == 1 )) && print -r -- "${m[1]}"
}

_cyc_next() {
	local cur="$1" i n k
	shift
	local -a a=("$@")
	n=${#a[@]}
	[[ "$n" -eq 0 ]] && return 0
	for ((i = 1; i <= n; i++)); do
		[[ "${a[i]}" == "$cur" ]] && { k=$((i + 1)); break; }
	done
	[[ -z "$k" ]] && k=1
	((k > n)) && k=1
	print -r -- "${a[k]}"
}

_cyc_restore() {
	local handle="$1" src creds cfg tmp
	src="$(_cyc_store)/$handle.json"
	[[ -f "$src" ]] || { print -u2 "cyc: no account '$handle'"; return 1; }
	creds=$(_cyc_creds)
	cfg=$(_cyc_cfg)
	command cp "$src" "$creds"
	command chmod 600 "$creds"
	# Force claude to refresh on next launch so it repopulates the cached
	# identity in ~/.claude.json from the profile endpoint for the new
	# account. Without this, claude sees a still-valid access token and
	# keeps the previous account's identity cached.
	tmp="${creds}.tmp.$$"
	jq 'del(.claudeAiOauth.accessToken) | .claudeAiOauth.expiresAt = 0' "$creds" > "$tmp" \
		&& command mv "$tmp" "$creds"
	[[ -f "$cfg" ]] || return 0
	tmp="${cfg}.tmp.$$"
	jq 'del(.oauthAccount)' "$cfg" > "$tmp" && command mv "$tmp" "$cfg"
}

_cyc_running_warn() {
	pgrep -x claude &>/dev/null && print -u2 "cyc: warning: claude is running; ~/.claude.json may be overwritten on exit"
}

cyc() {
	emulate -L zsh
	local req="$1" check method cur next star=""
	typeset -g _cyc_save_changed=0
	[[ -n $(_cyc_store) ]] || return 1
	check=$(_cyc_current_check)
	method=${check%%	*}
	cur=${check##*	}
	_cyc_running_warn
	case "$method" in
		refresh-token)
			_cyc_save_current "$cur" ;;
		oauth-email)
			print -u2 "cyc: warning: '$cur' from cached email only (token-match failed); live state suspect, not saving" ;;
		none)
			[[ -n "$req" ]] || { print -u2 "cyc: can't identify current account; specify one explicitly"; return 1; }
			print -u2 "cyc: warning: current account unknown; live credentials not saved" ;;
	esac
	local -a accounts=("${(@f)$(_cyc_accounts)}")
	if (( ${#accounts[@]} == 0 )); then
		print -u2 "cyc: no accounts in $(_cyc_store) — run cycImport first"
		return 1
	fi
	if [[ -n "$req" ]]; then
		next=$(_cyc_resolve "$req" "${accounts[@]}")
		[[ -z "$next" ]] && { print -u2 "cyc: no match for '$req' (have: ${accounts[*]})"; return 1; }
	else
		next=$(_cyc_next "$cur" "${accounts[@]}")
	fi
	_cyc_restore "$next" || return 1
	(( ${_cyc_save_changed:-0} )) && star=" *"
	print "$(date -Iseconds) cyc ${cur:-?} -> $next${req:+ ($req)}${star}" >> "${XDG_STATE_HOME:-$HOME/.local/state}/cyc.log"
	print "{\"account\":\"$next\",\"from\":\"${cur:-unknown}\"}$star"
}

cycLs() {
	emulate -L zsh
	[[ -n $(_cyc_store) ]] || return 1
	local cur=$(_cyc_current) a exp sub expstr mark
	for a in "${(@f)$(_cyc_accounts)}"; do
		exp=$(jq -r '.claudeAiOauth.expiresAt // 0' "$(_cyc_store)/$a.json" 2>/dev/null)
		sub=$(jq -r '.claudeAiOauth.subscriptionType // "??"' "$(_cyc_store)/$a.json" 2>/dev/null)
		expstr="?"
		[[ "$exp" == <-> && "$exp" -gt 0 ]] && expstr=$(date -d "@$((exp / 1000))" +"%F %H:%M" 2>/dev/null)
		mark=" "; [[ "$a" == "$cur" ]] && mark="*"
		printf '%s %-16s %-10s exp=%s\n' "$mark" "$a" "$sub" "$expstr"
	done
}

cycImport() {
	emulate -L zsh
	[[ -n $(_cyc_store) ]] || return 1
	local f name d count=0 check method cur
	command mkdir -p "$(_cyc_store)"
	for f in "$HOME/.claude"/cred-*.json(N); do
		name="${${f:t}#cred-}"
		name="${name%.json}"
		command cp "$f" "$(_cyc_store)/$name.json"
		command chmod 600 "$(_cyc_store)/$name.json"
		count=$((count + 1))
	done
	for f in "$(_cyc_store)"/*/credentials.json(N); do
		name="${${f:h}:t}"
		[[ -f "$(_cyc_store)/$name.json" ]] && continue
		command cp "$f" "$(_cyc_store)/$name.json"
		command chmod 600 "$(_cyc_store)/$name.json"
		count=$((count + 1))
	done
	check=$(_cyc_current_check)
	method=${check%%	*}
	cur=${check##*	}
	if [[ "$method" == "refresh-token" ]]; then
		_cyc_save_current "$cur"
		print "imported $count account(s) into $(_cyc_store) (seeded current: $cur)"
	elif [[ "$method" == "oauth-email" ]]; then
		print "imported $count account(s) into $(_cyc_store); skipped seed (token-match failed, cached email '$cur' but live state suspect)"
	else
		print "imported $count account(s) into $(_cyc_store); skipped seed (no current account identified)"
	fi
}

# Global alias: `--allow-skip` expands anywhere in a command line to the
# double flag combo the claude CLI needs to actually bypass permissions.
#   claude --allow-skip              → claude --allow-dangerously-skip-permissions --dangerously-skip-permissions
#   claude --allow-skip --resume x   → both flags + --resume x
alias -g -- '--allow-skip=--allow-dangerously-skip-permissions --dangerously-skip-permissions'
