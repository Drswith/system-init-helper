#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/tmp/system-init-$(date +%Y%m%d_%H%M%S).log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
step()  { echo -e "\n${BOLD}${BLUE}====> $* <====${NC}" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }

fail() {
    error "$*"
    exit 1
}

command_exists() {
    command -v "$1" &>/dev/null
}

get_ubuntu_codename() {
    lsb_release -cs 2>/dev/null || grep -oP 'UBUNTU_CODENAME=\K.*' /etc/os-release
}

STEP_COUNT=0
TOTAL_STEPS=6

next_step() {
    STEP_COUNT=$((STEP_COUNT + 1))
    step "[$STEP_COUNT/$TOTAL_STEPS] $*"
}

# ──────────────────────────────────────────────
# 0. Preflight
# ──────────────────────────────────────────────
step "[Preflight] Checking environment..."

[[ $EUID -ne 0 ]] && fail "Please run this script with sudo: sudo bash $0"
command_exists curl || { apt-get update -qq && apt-get install -y -qq curl; }
command_exists lsb_release || apt-get install -y -qq lsb-release

CODENAME=$(get_ubuntu_codename)
log "Detected Ubuntu codename: $CODENAME"
ok "Preflight passed. Log file: $LOG_FILE"

# ──────────────────────────────────────────────
# 1. Ubuntu Mirror Source
# ──────────────────────────────────────────────
next_step "Configuring Ubuntu mirror source (Aliyun)"

SOURCES_LIST="/etc/apt/sources.list"
SOURCES_BACKUP="/etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)"

if grep -q "mirrors.aliyun.com" "$SOURCES_LIST" 2>/dev/null; then
    warn "Aliyun mirror already configured in $SOURCES_LIST, skipping."
else
    if [[ -f "$SOURCES_LIST" ]]; then
        cp "$SOURCES_LIST" "$SOURCES_BACKUP"
        log "Backed up original sources.list to $SOURCES_BACKUP"
    fi

    cat > "$SOURCES_LIST" <<EOF
# Aliyun Mirror - Ubuntu $CODENAME
deb http://mirrors.aliyun.com/ubuntu/ $CODENAME main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ $CODENAME-security main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ $CODENAME-backports main restricted universe multiverse
# deb-src
deb-src http://mirrors.aliyun.com/ubuntu/ $CODENAME main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ $CODENAME-security main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ $CODENAME-backports main restricted universe multiverse
EOF

    log "Running apt-get update..."
    apt-get update -qq
    ok "Ubuntu mirror source configured and updated."
fi

# ──────────────────────────────────────────────
# 2. Base packages
# ──────────────────────────────────────────────
next_step "Installing base packages"

BASE_PACKAGES=(
    git
    curl
    wget
    build-essential
    unzip
    ca-certificates
    gnupg
    software-properties-common
    jq
    ripgrep
    fd-find
    fzf
    bat
    eza
    tldr
)

log "Installing: ${BASE_PACKAGES[*]}"
apt-get install -y -qq "${BASE_PACKAGES[@]}"

ln -sf "$(which fdfind)" /usr/local/bin/fd 2>/dev/null || true
ln -sf "$(which batcat)" /usr/local/bin/bat 2>/dev/null || true

ok "Base packages installed."

# ──────────────────────────────────────────────
# 3. Zsh + Oh-My-Zsh
# ──────────────────────────────────────────────
next_step "Installing Zsh and Oh-My-Zsh with Gitee mirror"

CURRENT_USER="${SUDO_USER:-$USER}"
CURRENT_USER_HOME=$(eval echo "~$CURRENT_USER")

log "Installing zsh..."
apt-get install -y -qq zsh

ZSH_VERSION=$(zsh --version)
log "$ZSH_VERSION installed."

CURRENT_SHELL=$(getent passwd "$CURRENT_USER" | cut -d: -f7)
if [[ "$CURRENT_SHELL" == *"zsh"* ]]; then
    warn "zsh is already the default shell for $CURRENT_USER, skipping."
else
    log "Setting zsh as default shell for user $CURRENT_USER..."
    chsh -s "$(which zsh)" "$CURRENT_USER"
    ok "Default shell changed to zsh for $CURRENT_USER"
fi

OH_MY_ZSH_DIR="$CURRENT_USER_HOME/.oh-my-zsh"

if [[ ! -d "$OH_MY_ZSH_DIR" ]]; then
    log "Installing Oh-My-Zsh from Gitee mirror..."
    git clone --depth=1 https://gitee.com/mirrors/oh-my-zsh.git "$OH_MY_ZSH_DIR"
    chown -R "$CURRENT_USER:$CURRENT_USER" "$OH_MY_ZSH_DIR"

    ZSHRC="$CURRENT_USER_HOME/.zshrc"
    if [[ -f "$ZSHRC" ]] && grep -q "oh-my-zsh" "$ZSHRC"; then
        warn ".zshrc already has oh-my-zsh config, skipping."
    else
        cp "$OH_MY_ZSH_DIR/templates/zshrc.zsh-template" "$ZSHRC"
        chown "$CURRENT_USER:$CURRENT_USER" "$ZSHRC"
    fi

    log "Configuring oh-my-zsh update mirror to Gitee..."
    OMZ_CUSTOM="${OH_MY_ZSH_DIR}/custom"
    mkdir -p "$OMZ_CUSTOM"

    ZSH_CUSTOM_ENV="/etc/profile.d/oh-my-zsh-mirror.sh"
    cat > "$ZSH_CUSTOM_ENV" <<'EOF'
ZSH_UPDATE_REPO=https://gitee.com/mirrors/oh-my-zsh.git
ZSH_UPDATE_CHANNEL=gitee
EOF
    chmod +x "$ZSH_CUSTOM_ENV"

    sed -i 's|^# zstyle ':omz:update' auto|zstyle ':omz:update' auto|' "$ZSHRC" 2>/dev/null || true

    ok "Oh-My-Zsh installed from Gitee mirror."
else
    warn "Oh-My-Zsh already installed at $OH_MY_ZSH_DIR, skipping."
fi

ok "Zsh + Oh-My-Zsh (Gitee mirror) configured."

# ──────────────────────────────────────────────
# 4. fnm + Node.js + npmmirror
# ──────────────────────────────────────────────
next_step "Installing fnm, Node.js LTS and configuring npmmirror"

FNM_DIR="/usr/local/share/fnm"

if ! command_exists fnm; then
    log "Installing fnm from GitHub releases..."
    ARCH=$(uname -m)
    case "$ARCH" in
        arm | armv7*) FNM_FILE="fnm-arm32" ;;
        aarch* | armv8*) FNM_FILE="fnm-arm64" ;;
        *) FNM_FILE="fnm-linux" ;;
    esac

    FNM_URL="https://github.com/Schniz/fnm/releases/latest/download/${FNM_FILE}.zip"

    FNM_TMP=$(mktemp -d)
    log "Downloading fnm ($FNM_FILE) via gh-proxy..."
    if ! curl --progress-bar --fail -L "https://gh-proxy.com/${FNM_URL}" -o "$FNM_TMP/fnm.zip" 2>/dev/null; then
        warn "gh-proxy.com failed, trying GitHub directly..."
        curl --progress-bar --fail -L "$FNM_URL" -o "$FNM_TMP/fnm.zip" || fail "Failed to download fnm from both sources."
    fi

    mkdir -p "$FNM_DIR"
    unzip -q -o "$FNM_TMP/fnm.zip" -d "$FNM_TMP/out"
    if [[ -f "$FNM_TMP/out/fnm" ]]; then
        mv "$FNM_TMP/out/fnm" "$FNM_DIR/fnm"
    else
        mv "$FNM_TMP/out/$FNM_FILE/fnm" "$FNM_DIR/fnm"
    fi
    chmod +x "$FNM_DIR/fnm"
    ln -sf "$FNM_DIR/fnm" /usr/local/bin/fnm
    rm -rf "$FNM_TMP"
    ok "fnm installed."
else
    warn "fnm already installed, skipping."
fi

log "Configuring fnm for zsh..."
ZSHRC="$CURRENT_USER_HOME/.zshrc"
FNM_BLOCK="$CURRENT_USER_HOME/.zsh_fnm"
cat > "$FNM_BLOCK" <<'EOF'
export FNM_PATH="/usr/local/share/fnm"
export PATH="$FNM_PATH:$PATH"
eval "$(fnm env --use-on-cd --shell zsh)"
EOF
chown "$CURRENT_USER:$CURRENT_USER" "$FNM_BLOCK"

if ! grep -q "zsh_fnm" "$ZSHRC" 2>/dev/null; then
    echo '' >> "$ZSHRC"
    echo 'source $HOME/.zsh_fnm' >> "$ZSHRC"
    chown "$CURRENT_USER:$CURRENT_USER" "$ZSHRC"
fi

export FNM_PATH="$FNM_DIR"
export PATH="$FNM_PATH:$PATH"
eval "$(fnm env --use-on-cd --shell bash)"

if command_exists node; then
    NODE_VERSION=$(node -v)
    warn "Node.js $NODE_VERSION already installed, skipping."
else
    log "Installing Node.js LTS via fnm..."
    fnm install --lts
    fnm use --lts
    fnm default lts-latest
    NODE_VERSION=$(node -v)
    log "Node.js version: $NODE_VERSION"
fi

NPM_REGISTRY=$(npm config get registry 2>/dev/null)
if [[ "$NPM_REGISTRY" == *"npmmirror"* ]]; then
    warn "npm registry already set to npmmirror, skipping."
else
    log "Configuring npm mirror (npmmirror)..."
    npm config set registry https://registry.npmmirror.com -g
    ok "npm registry set to https://registry.npmmirror.com"
fi

NPMRC="/etc/skel/.npmrc"
if [[ ! -f "$NPMRC" ]] || ! grep -q "npmmirror" "$NPMRC" 2>/dev/null; then
    cat > "$NPMRC" <<EOF
registry=https://registry.npmmirror.com
EOF
fi

ok "fnm + Node.js $(node -v) + npmmirror configured."

# ──────────────────────────────────────────────
# 5. Bun
# ──────────────────────────────────────────────
next_step "Installing Bun"

if ! command_exists bun; then
    log "Installing Bun via official install script (gh-proxy accelerated)..."
    GITHUB=https://gh-proxy.com/https://github.com curl -fsSL https://bun.sh/install | GITHUB=https://gh-proxy.com/https://github.com bash
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"

    ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun 2>/dev/null || true

    BUN_VERSION=$(bun -v)
    ok "Bun $BUN_VERSION installed."
else
    warn "Bun already installed, skipping."
fi

log "Configuring bun for zsh..."
BUN_BLOCK="$CURRENT_USER_HOME/.zsh_bun"
if [[ -f "$BUN_BLOCK" ]] && grep -q "zsh_bun" "$ZSHRC" 2>/dev/null; then
    warn "Bun zsh config already exists, skipping."
else
    cat > "$BUN_BLOCK" <<'EOF'
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
EOF
    chown "$CURRENT_USER:$CURRENT_USER" "$BUN_BLOCK"

    if ! grep -q "zsh_bun" "$ZSHRC" 2>/dev/null; then
        echo '' >> "$ZSHRC"
        echo 'source $HOME/.zsh_bun' >> "$ZSHRC"
        chown "$CURRENT_USER:$CURRENT_USER" "$ZSHRC"
    fi
    ok "Bun zsh config written."
fi

# ──────────────────────────────────────────────
# 6. Python + pip mirror
# ──────────────────────────────────────────────
next_step "Installing Python and configuring pip mirror"
PYTHON_PKGS=(
    python3
    python3-pip
    python3-venv
    python3-dev
)

log "Installing Python packages: ${PYTHON_PKGS[*]}"
apt-get install -y -qq "${PYTHON_PKGS[@]}"

PYTHON_VERSION=$(python3 --version)
log "$PYTHON_VERSION installed."

log "Configuring pip mirror (Aliyun)..."
PIP_CONF="/etc/pip.conf"
if grep -q "mirrors.aliyun.com" "$PIP_CONF" 2>/dev/null; then
    warn "pip mirror already configured, skipping."
else
    mkdir -p /etc/pip.conf.d
    cat > "$PIP_CONF" <<EOF
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = mirrors.aliyun.com
EOF
    chmod 644 "$PIP_CONF"

    for USER_SKELETON in /etc/skel /root; do
        mkdir -p "$USER_SKELETON/.pip"
        cat > "$USER_SKELETON/.pip/pip.conf" <<EOF
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = mirrors.aliyun.com
EOF
    done
    ok "pip mirror configured."
fi

log "Installing common Python tools..."
pip3 install --quiet --upgrade pip setuptools wheel

ok "Python $PYTHON_VERSION + pip mirror configured."
ok "pip index-url set to https://mirrors.aliyun.com/pypi/simple/"

# ──────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  All done! System initialization completed successfully.  ${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "${CYAN}  Node.js:${NC}  $(node -v)"
echo -e "${CYAN}  npm:${NC}      $(npm -v)"
echo -e "${CYAN}  Bun:${NC}      $(bun -v 2>/dev/null || echo 'run source /etc/profile.d/bun.sh first')"
echo -e "${CYAN}  Python:${NC}   $(python3 --version)"
echo -e "${CYAN}  pip:${NC}      $(pip3 --version | awk '{print $2}')"
echo -e "${CYAN}  Zsh:${NC}      $(zsh --version)"
echo -e "${CYAN}  Shell:${NC}    zsh (for user $CURRENT_USER)"
echo ""
echo -e "${YELLOW}  Log file: $LOG_FILE${NC}"
echo -e "${YELLOW}  Open a new terminal (zsh) to load the environment.${NC}"
echo ""
