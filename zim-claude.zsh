# @description Print the credential store directory path.
# @stdout ${CLAUDE_CREDS_DIR:-$HOME/.claude/creds}.
# @stderr Error message if neither CLAUDE_CREDS_DIR nor $HOME is set.
# @exitcode 0 Success.
# @exitcode 1 Neither CLAUDE_CREDS_DIR nor $HOME is set.
# @internal
_cyc_store() {
	[[ -n "$CLAUDE_CREDS_DIR$HOME" ]] || { print -u2 "cyc: neither CLAUDE_CREDS_DIR nor \$HOME is set — can't locate credential store"; return 1; }
	print -r -- "${CLAUDE_CREDS_DIR:-$HOME/.claude/creds}"
}

# @description Print the live credentials file path.
# @stdout ~/.claude/.credentials.json.
# @internal
_cyc_creds() { print -r -- "$HOME/.claude/.credentials.json" }

# @description Print the claude.json config file path.
# @stdout ~/.claude.json.
# @internal
_cyc_cfg() { print -r -- "$HOME/.claude.json" }

# @description Identify the current account by refresh-token match or cached email.
#
# Reads the live refresh token from .credentials.json and scans stored
# files for a match. If no match, falls back to oauthAccount.emailAddress
# from ~/.claude.json when a stored file exists for that email.
#
# @stdout "<method>\t<handle>" where method is one of:
#   refresh-token  live refresh token matched a stored file (high confidence)
#   oauth-email    token match failed; cached email mapped to a stored file
#                  (lower confidence — cached identity, may be stale)
#   none           no refresh token, no email, or no matching stored file
# Handle is the file stem — full email under creds/<email>.json naming,
# or whatever stem a legacy file was saved under.
# @internal
_cyc_cur() {
	local rt f stored email
	rt=$(jq -r '(.credentials.claudeAiOauth.refreshToken // .claudeAiOauth.refreshToken // empty)' "$(_cyc_creds)" 2>/dev/null)
	if [[ -n "$rt" ]]; then
		for f in "$(_cyc_store)"/*.json(N); do
			stored=$(jq -r '(.credentials.claudeAiOauth.refreshToken // .claudeAiOauth.refreshToken // empty)' "$f" 2>/dev/null)
			if [[ "$stored" == "$rt" ]]; then
				print -r -- "refresh-token	${${f:t}%.json}"
				return
			fi
		done
	fi
	email=$(jq -r '.oauthAccount.emailAddress // empty' "$(_cyc_cfg)" 2>/dev/null)
	if [[ -n "$email" ]] && [[ -f "$(_cyc_store)/$email.json" ]]; then
		print -r -- "oauth-email	$email"
		return
	fi
	print -r -- "none	"
}

# @description List stored account handles (file stems), one per line, sorted.
# @stdout Sorted list of account handles.
# @internal
_cyc_accounts() {
	local f
	local -a out=()
	[[ -d "$(_cyc_store)" ]] || return 0
	for f in "$(_cyc_store)"/*.json(N); do out+=("${${f:t}%.json}"); done
	print -rl -- "${(@on)out}"
}

# @description Enumerate all stored accounts as JSON lines.
#
# Reads each stored file exactly once and emits one compact JSON object
# per line. Designed as the lower-level enumerator that cycLs (display)
# and other tools consume.
#
# @stdout One JSON object per line, with fields:
#   handle            file stem (email under new naming, else legacy stem)
#   email             settings.oauthAccount.emailAddress (null if absent)
#   displayName       settings.oauthAccount.displayName (null if absent)
#   subscriptionType  claudeAiOauth.subscriptionType (null if absent)
#   expiresAt         claudeAiOauth.expiresAt in ms epoch (null if absent)
#   hasRefresh        bool — refresh token present and non-empty
#   hasAccess         bool — access token present and non-empty
#   isExpired         bool — expiresAt older than now (true if expiresAt missing)
#   isLegacy          bool — file uses old format (no credentials/settings wrapper)
#   hasOauthAccount   bool — settings.oauthAccount block present
# @internal
_cyc_ls() {
	local f
	local now_ms=$(( $(date +%s) * 1000 ))
	[[ -d "$(_cyc_store)" ]] || return 0
	for f in "$(_cyc_store)"/*.json(N); do
		jq -c --arg handle "${${f:t}%.json}" --argjson now "$now_ms" '{
			handle: $handle,
			email: (.settings.oauthAccount.emailAddress // null),
			displayName: (.settings.oauthAccount.displayName // null),
			subscriptionType: (.credentials.claudeAiOauth.subscriptionType // .claudeAiOauth.subscriptionType // null),
			expiresAt: (.credentials.claudeAiOauth.expiresAt // .claudeAiOauth.expiresAt // null),
			hasRefresh: ((.credentials.claudeAiOauth.refreshToken // .claudeAiOauth.refreshToken // "") | length > 0),
			hasAccess: ((.credentials.claudeAiOauth.accessToken // .claudeAiOauth.accessToken // "") | length > 0),
			isExpired: ((.credentials.claudeAiOauth.expiresAt // .claudeAiOauth.expiresAt // 0) < $now),
			isLegacy: (.credentials == null),
			hasOauthAccount: (.settings.oauthAccount != null)
		}' "$f"
	done
}

# @description Capture live state into a stored account file.
#
# Reads claudeAiOauth from .credentials.json and oauthAccount from
# ~/.claude.json, writes both verbatim into <handle>.json under the
# path-mirroring structure:
#   credentials.claudeAiOauth  <-  ~/.claude/.credentials.json
#   settings.oauthAccount      <-  ~/.claude.json
#
# @arg $1 Handle (file stem) for the stored file. Typically the full email.
# @internal
_cyc_save_current() {
	local handle="$1" dest creds cfg tmp
	[[ -n "$handle" && -f "$(_cyc_creds)" ]] || return 1
	command mkdir -p "$(_cyc_store)"
	dest="$(_cyc_store)/$handle.json"
	creds=$(_cyc_creds)
	cfg=$(_cyc_cfg)
	tmp="${dest}.tmp.$$"
	typeset -g _cyc_save_changed=0
	jq -n --slurpfile c "$creds" --slurpfile g "$cfg" '{
		credentials: { claudeAiOauth: $c[0].claudeAiOauth },
		settings: { oauthAccount: $g[0].oauthAccount }
	}' > "$tmp"
	[[ -f "$dest" ]] && ! command cmp -s "$dest" "$tmp" && _cyc_save_changed=1
	command mv "$tmp" "$dest"
	command chmod 600 "$dest"
}

# @description Resolve a user-provided name to a stored handle.
#
# Matches by exact handle, exact local-part (prefix before @), or unique
# prefix. Returns the first exact match, or the only prefix match.
#
# @arg $1 Needle (name, email, or prefix).
# @arg $@ List of stored handles to search.
# @stdout The resolved handle, or empty if no unique match.
# @internal
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

# @description Pick the next handle alphabetically after $cur, wrapping.
# @arg $1 Current handle (may be empty — returns first handle).
# @arg $@ List of handles (alphabetical order expected).
# @stdout The next handle, or empty if list is empty.
# @internal
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

# @description Restore a stored account into live state.
#
# CURRENT LIMITATION: writes the stored file verbatim to .credentials.json
# and strips the access token + deletes oauthAccount to force a refresh.
# Does NOT yet handle the new credentials/settings structure — pending redo.
#
# @arg $1 Handle (file stem) of the stored account.
# @stderr Error message if no stored file exists for $handle.
# @exitcode 0 Success.
# @exitcode 1 No stored file for $handle.
# @internal
_cyc_restore() {
	local handle="$1" src creds cfg tmp
	src="$(_cyc_store)/$handle.json"
	[[ -f "$src" ]] || { print -u2 "cyc: no account '$handle'"; return 1; }
	creds=$(_cyc_creds)
	cfg=$(_cyc_cfg)
	command cp "$src" "$creds"
	command chmod 600 "$creds"
	tmp="${creds}.tmp.$$"
	jq 'del(.claudeAiOauth.accessToken) | .claudeAiOauth.expiresAt = 0' "$creds" > "$tmp" \
		&& command mv "$tmp" "$creds"
	[[ -f "$cfg" ]] || return 0
	tmp="${cfg}.tmp.$$"
	jq 'del(.oauthAccount)' "$cfg" > "$tmp" && command mv "$tmp" "$cfg"
}

# @description Warn on stderr if claude is running.
# @stderr Warning if claude is in the process table.
# @internal
_cyc_running_warn() {
	pgrep -x claude &>/dev/null && print -u2 "cyc: warning: claude is running; ~/.claude.json may be overwritten on exit"
}

# @description Rotate the live claude account.
#
# With no arg: rotate to the next alphabetical handle (after saving the
# current account). With an arg: switch to a specific handle (exact name,
# local-part, or unique prefix).
#
# Refuses to save the outgoing account unless _cyc_cur returns
# refresh-token confidence (skips save on oauth-email or none to avoid
# corrupting stored files with bad live state).
#
# @arg $1 Optional target handle (name, email, or unique prefix).
# @stdout JSON result: {"account":<next>,"from":<cur>} plus " *" if a
#   refresh was captured by save-before-switch.
# @stderr Warnings (claude running, unknown current, no match, no accounts).
# @exitcode 0 Success.
# @exitcode 1 Store unset, no stored accounts, or no match for $1.
cyc() {
	emulate -L zsh
	local req="$1" check method cur next star=""
	typeset -g _cyc_save_changed=0
	[[ -n $(_cyc_store) ]] || return 1
	check=$(_cyc_cur)
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
		print -u2 "cyc: no accounts in $(_cyc_store) — run cycExport first"
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

# @description List stored accounts with current marker and validity state.
#
# @stdout One line per account:
#   <mark> <email|handle> <sub> exp=<YYYY-MM-DD HH:MM> [<state>]
# Where:
#   mark  '*' current via refresh-token, '?' current via oauth-email, ' ' else
#   state comma-separated flags drawn from _cyc_ls validity fields:
#     ok    fully valid (default when no flags apply)
#     old   isLegacy — file is in pre-oauthAccount format
#     noR   hasRefresh false — refresh token missing
#     exp   isExpired — access token older than now
#     noId  hasOauthAccount false — settings.oauthAccount absent
# @exitcode 0 Success.
# @exitcode 1 Store path unset.
cycLs() {
	emulate -L zsh
	[[ -n $(_cyc_store) ]] || return 1
	local check method cur line handle email sub exp expstr mark state
	local isLegacy hasRefresh isExpired hasOauthAccount
	check=$(_cyc_cur)
	method=${check%%	*}
	cur=${check##*	}
	_cyc_ls | while IFS= read -r line; do
		handle=$(print -r -- "$line" | jq -r '.handle')
		email=$(print -r -- "$line" | jq -r '.email // .handle')
		sub=$(print -r -- "$line" | jq -r '.subscriptionType // "??"')
		exp=$(print -r -- "$line" | jq -r '.expiresAt // 0')
		isLegacy=$(print -r -- "$line" | jq -r '.isLegacy')
		hasRefresh=$(print -r -- "$line" | jq -r '.hasRefresh')
		isExpired=$(print -r -- "$line" | jq -r '.isExpired')
		hasOauthAccount=$(print -r -- "$line" | jq -r '.hasOauthAccount')
		expstr="?"
		[[ "$exp" == <-> && "$exp" -gt 0 ]] && expstr=$(date -d "@$((exp / 1000))" +"%F %H:%M" 2>/dev/null)
		state=""
		[[ "$isLegacy" == "true" ]] && state="${state:+$state,}old"
		[[ "$hasRefresh" != "true" ]] && state="${state:+$state,}noR"
		[[ "$isExpired" == "true" ]] && state="${state:+$state,}exp"
		[[ "$hasOauthAccount" != "true" ]] && state="${state:+$state,}noId"
		[[ -z "$state" ]] && state="ok"
		mark=" "
		if [[ "$method" != "none" && "$handle" == "$cur" ]]; then
			[[ "$method" == "refresh-token" ]] && mark="*" || mark="?"
		fi
		printf '%s %-30s %-8s exp=%-16s [%s]\n' "$mark" "$email" "$sub" "$expstr" "$state"
	done
}

# @description Capture the live account into the store.
#
# Reads oauthAccount.emailAddress from ~/.claude.json and captures both
# claudeAiOauth (from .credentials.json) and oauthAccount verbatim into
# creds/<email>.json with the path-mirroring structure
# {credentials.claudeAiOauth, settings.oauthAccount}.
#
# @stderr Error if no oauthAccount.emailAddress (not logged in) or capture fails.
# @stdout Confirmation: "captured <email> -> <path>".
# @exitcode 0 Success.
# @exitcode 1 Store unset, not logged in, or capture failed.
cycExport() {
	emulate -L zsh
	[[ -n $(_cyc_store) ]] || return 1
	local email
	command mkdir -p "$(_cyc_store)"
	email=$(jq -r '.oauthAccount.emailAddress // empty' "$(_cyc_cfg)" 2>/dev/null)
	[[ -n "$email" ]] || { print -u2 "cycExport: no oauthAccount.emailAddress in $(_cyc_cfg) — log in via claude first"; return 1; }
	_cyc_save_current "$email" || { print -u2 "cycExport: capture failed for $email"; return 1; }
	print "captured $email -> $(_cyc_store)/$email.json"
}

# Global alias: `--allow-skip` expands anywhere in a command line to the
# double flag combo the claude CLI needs to actually bypass permissions.
#   claude --allow-skip              -> claude --allow-dangerously-skip-permissions --dangerously-skip-permissions
#   claude --allow-skip --resume x   -> both flags + --resume x
alias -g -- '--allow-skip=--allow-dangerously-skip-permissions --dangerously-skip-permissions'
