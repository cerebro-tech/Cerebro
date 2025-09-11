# Alias
alias cbro="$HOME/cerebro/cerebro_rambuild.sh"

# Build local directory
cbro ~/Downloads/mypkg

# Build AUR package
cbro paru

# Build URL
cbro https://example.com/somepkg.tar.zst

# Build and keep RAM build dir
cbro paru --keep
