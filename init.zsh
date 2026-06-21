# zim-claude: rotate the Claude Code CLI account across multiple OAuth logins
# Zimfw entry point. Sources zim-claude.zsh, which can also be loaded
# directly via ~/.config/zsh/conf.d/zim-claude.conf (a symlink).

(( ${+commands[claude]} )) || return

source "${0:h}/zim-claude.zsh"
