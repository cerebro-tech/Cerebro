#📦 Powerlevel10k Instant Prompt (pre-zsh load)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

#⚙️  Base Environment Setup
export ZDOTDIR="$HOME"
export EDITOR="nano"
export PAGER="less"
export PATH="$HOME/my_scripts:$PATH"

#🎨 Powerlevel10k Theme
source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme

#🔌 Zgenom Plugin Manager (manual Git install)
ZGEN_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zgenom"
source ~/.zgenom/zgenom.zsh

#🚀 Plugin Load
zgenom load zsh-users/zsh-completions
zgenom load zsh-users/zsh-autosuggestions
zgenom load marlonrichert/zsh-autocomplete
zgenom load zdharma-continuum/zsh-fast-syntax-highlighting

#🧪 Save snapshot if not done
if ! zgenom saved; then
  zgenom save
fi

#🔧 Plugin Settings
# zsh-autosuggestions
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=32
ZSH_AUTOSUGGEST_USE_ASYNC=1

# zsh-autocomplete
zstyle ':autocomplete:*' fzf-completion yes
zstyle ':autocomplete:*' widget-style menu-select

# Completion behavior
autoload -Uz compinit && compinit -C
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'

#⚙️  Zsh Options
setopt no_beep
setopt prompt_subst
setopt HIST_IGNORE_SPACE

#⌨️  Keybindings (no substring search)
bindkey '^?' backward-delete-char      # Backspace
bindkey '^[[3~' delete-char            # Delete key
bindkey '^[[1;5C' forward-word         # Ctrl + Right arrow
bindkey '^[[1;5D' backward-word        # Ctrl + Left arrow

#🔁 Aliases
alias ls='ls --color=auto'
alias la='ls -la'
alias pac='sudo pacman'
alias updatearch='pac -Sc --noconfirm && paru -Sc --noconfirm && sudo fstrim -av && pac -Syu --needed --noconfirm && paru -Syu --needed --noconfirm'
#alias dobackup='sudo /home/j/my_scripts/Do_Backup/cerebro_backup.sh'

# 🔍 fzf Settings
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# 🎨 Powerlevel10k Config
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# 🚀 Git Automation Function
unalias dogit 2>/dev/null
dogit() {
  local msg
  cd /home/j/my_scripts || return
  echo "Enter commit message:"
  read -r msg
  git pull origin main
  git add -A
  if git diff --cached --quiet; then
    echo "No changes to commit."
  else
    git commit -m "$msg"
    git push origin main
  fi
}
alias rbuild='~/my_scripts/ram_build.sh -sic'
