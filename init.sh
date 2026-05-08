#!/usr/bin/env bash
set -euo pipefail

SCRIPT_START=$(date +%s)
LOG_FILE="/tmp/system-init-$(date +%Y%m%d_%H%M%S).log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SPINNER_PID=""
STEP_START=0

spinner() {
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while true; do
        for ((i=0; i<${#chars}; i++)); do
            printf "\r  ${CYAN}${chars:$i:1}${NC} $*..."
            sleep 0.1
        done
    done
}

start_spinner() {
    STEP_START=$(date +%s)
    spinner "$*" &
    SPINNER_PID=$!
}

stop_spinner() {
    if [[ -n "$SPINNER_PID" ]] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
    fi
    local elapsed=0
    if [[ "$STEP_START" -gt 0 ]]; then
        elapsed=$(( $(date +%s) - STEP_START ))
    fi
    printf "\r%*s\r" 60 ""
    if [[ "$elapsed" -gt 0 ]]; then
        echo -e "  ${DIM}(${elapsed}s)${NC}" | tee -a "$LOG_FILE"
    fi
    SPINNER_PID=""
}

step_elapsed() {
    local elapsed=0
    if [[ "$STEP_START" -gt 0 ]]; then
        elapsed=$(( $(date +%s) - STEP_START ))
    fi
    if [[ "$elapsed" -gt 0 ]]; then
        echo -e "  ${DIM}(${elapsed}s)${NC}" | tee -a "$LOG_FILE"
    fi
}

DIM='\033[0;2m'

log()   { stop_spinner; echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
warn()  { stop_spinner; echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error() { stop_spinner; echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
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
TOTAL_STEPS=10

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
SOURCES_DEB822="/etc/apt/sources.list.d/ubuntu.sources"
SOURCES_BACKUP="/etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)"

if grep -q "mirrors.aliyun.com" "$SOURCES_LIST" 2>/dev/null || grep -q "mirrors.aliyun.com" "$SOURCES_DEB822" 2>/dev/null; then
    warn "Aliyun mirror already configured, skipping."
else
    if [[ -f "$SOURCES_LIST" ]]; then
        cp "$SOURCES_LIST" "$SOURCES_BACKUP"
        log "Backed up original sources.list to $SOURCES_BACKUP"
    fi
    if [[ -f "$SOURCES_DEB822" ]]; then
        cp "$SOURCES_DEB822" "${SOURCES_DEB822}.bak.$(date +%Y%m%d%H%M%S)"
        log "Backed up ubuntu.sources"
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

    if [[ -f "$SOURCES_DEB822" ]]; then
        rm -f "$SOURCES_DEB822"
        log "Removed DEB822 format ubuntu.sources to avoid duplicate sources."
    fi

    log "Running apt-get update..."
    start_spinner "Updating package index"
    apt-get update -qq
    stop_spinner
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
start_spinner "Installing base packages (${#BASE_PACKAGES[@]} packages)"
apt-get install -y -qq "${BASE_PACKAGES[@]}"
stop_spinner

ln -sf "$(which fdfind)" /usr/local/bin/fd 2>/dev/null || true
ln -sf "$(which batcat)" /usr/local/bin/bat 2>/dev/null || true

ok "Base packages installed."

# ──────────────────────────────────────────────
# 3. Zsh + Oh-My-Zsh
# ──────────────────────────────────────────────
next_step "Installing Zsh and Oh-My-Zsh with Gitee mirror"

CURRENT_USER="${SUDO_USER:-${USER:-root}}"
CURRENT_USER_HOME=$(eval echo "~$CURRENT_USER")

log "Installing zsh..."
start_spinner "Installing zsh"
apt-get install -y -qq zsh
stop_spinner

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
    start_spinner "Cloning Oh-My-Zsh from Gitee"
    git clone --depth=1 https://gitee.com/mirrors/oh-my-zsh.git "$OH_MY_ZSH_DIR"
    stop_spinner
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

source "$CURRENT_USER_HOME/.zshrc" 2>/dev/null || true

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
    start_spinner "Downloading fnm binary"
    if ! curl --progress-bar --fail -L "https://gh-proxy.com/${FNM_URL}" -o "$FNM_TMP/fnm.zip" 2>/dev/null; then
        stop_spinner
        warn "gh-proxy.com failed, trying GitHub directly..."
        start_spinner "Downloading fnm from GitHub"
        curl --progress-bar --fail -L "$FNM_URL" -o "$FNM_TMP/fnm.zip" || fail "Failed to download fnm from both sources."
    fi
    stop_spinner

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
export FNM_DIR="/usr/local/share/fnm"
export FNM_NODE_DIST_MIRROR="https://npmmirror.com/mirrors/node"
export PATH="$FNM_DIR:$PATH"
eval "$(fnm env --use-on-cd --shell zsh)"
EOF
chown "$CURRENT_USER:$CURRENT_USER" "$FNM_BLOCK"

    if ! grep -q "zsh_fnm" "$ZSHRC" 2>/dev/null; then
        echo '' >> "$ZSHRC"
        echo 'source $HOME/.zsh_fnm' >> "$ZSHRC"
        chown "$CURRENT_USER:$CURRENT_USER" "$ZSHRC"
    fi
    source "$CURRENT_USER_HOME/.zsh_fnm" 2>/dev/null || true

export FNM_DIR="$FNM_DIR"
export FNM_NODE_DIST_MIRROR="https://npmmirror.com/mirrors/node"
export PATH="$FNM_DIR:$PATH"
eval "$(fnm env)"

if command_exists node; then
    NODE_VERSION=$(node -v)
    warn "Node.js $NODE_VERSION already installed, skipping."
else
    log "Installing Node.js LTS via fnm..."
    start_spinner "Downloading and installing Node.js LTS"
    fnm install --lts
    stop_spinner
    fnm default "$(fnm current)"
    NODE_VERSION=$(node -v)
    log "Node.js version: $NODE_VERSION"
fi

chmod -R a+rx "$FNM_DIR/nodejs" 2>/dev/null || true

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
    start_spinner "Downloading and installing Bun"
    GITHUB=https://gh-proxy.com/https://github.com curl -fsSL https://bun.sh/install | GITHUB=https://gh-proxy.com/https://github.com bash
    stop_spinner
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
    source "$CURRENT_USER_HOME/.zsh_bun" 2>/dev/null || true
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
start_spinner "Installing Python packages"
apt-get install -y -qq "${PYTHON_PKGS[@]}"
stop_spinner

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
start_spinner "Upgrading pip, setuptools, wheel"
pip3 install --quiet --break-system-packages --ignore-installed pip setuptools wheel
stop_spinner

ok "Python $PYTHON_VERSION + pip mirror configured."
ok "pip index-url set to https://mirrors.aliyun.com/pypi/simple/"

# ──────────────────────────────────────────────
# 7. uv (Python package manager)
# ──────────────────────────────────────────────
next_step "Installing uv (Python package manager)"

if ! command_exists uv; then
    log "Installing uv via official install script (gh-proxy accelerated)..."
    start_spinner "Downloading and installing uv"
    UV_INSTALLER_URL="https://gh-proxy.com/https://github.com/astral-sh/uv/releases/latest/download/uv-installer.sh"
    if ! curl -fsSL "$UV_INSTALLER_URL" | sh 2>/dev/null; then
        stop_spinner
        warn "gh-proxy.com failed, trying GitHub directly..."
        start_spinner "Downloading uv from GitHub"
        curl -fsSL https://astral.sh/uv/install.sh | sh || fail "Failed to install uv."
    fi
    stop_spinner

    export UV_HOME="$HOME/.local/bin"
    export PATH="$UV_HOME:$PATH"
    ln -sf "$HOME/.local/bin/uv" /usr/local/bin/uv 2>/dev/null || true
    ln -sf "$HOME/.local/bin/uvx" /usr/local/bin/uvx 2>/dev/null || true

    UV_VERSION=$(uv --version 2>/dev/null | head -1)
    ok "uv $UV_VERSION installed."
else
    warn "uv already installed, skipping."
fi

log "Configuring uv for zsh..."
UV_BLOCK="$CURRENT_USER_HOME/.zsh_uv"
if [[ -f "$UV_BLOCK" ]] && grep -q "zsh_uv" "$ZSHRC" 2>/dev/null; then
    warn "uv zsh config already exists, skipping."
else
    cat > "$UV_BLOCK" <<'EOF'
export UV_HOME="$HOME/.local/bin"
export PATH="$UV_HOME:$PATH"
EOF
    chown "$CURRENT_USER:$CURRENT_USER" "$UV_BLOCK"

    if ! grep -q "zsh_uv" "$ZSHRC" 2>/dev/null; then
        echo '' >> "$ZSHRC"
        echo 'source $HOME/.zsh_uv' >> "$ZSHRC"
        chown "$CURRENT_USER:$CURRENT_USER" "$ZSHRC"
    fi
    source "$CURRENT_USER_HOME/.zsh_uv" 2>/dev/null || true
    ok "uv zsh config written."
fi

ok "uv $(uv --version 2>/dev/null | awk '{print $2}') configured."

# ──────────────────────────────────────────────
# 8. GitHub CLI
# ──────────────────────────────────────────────
next_step "Installing GitHub CLI (gh)"

if ! command_exists gh; then
    log "Adding GitHub CLI apt repository..."
    mkdir -p -m 755 /etc/apt/keyrings

    GPG_KEYRING="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
    log "Downloading GitHub CLI keyring..."
    start_spinner "Downloading keyring"
    if ! curl -fsSL "https://gh-proxy.com/https://cli.github.com/packages/githubcli-archive-keyring.gpg" -o "$GPG_KEYRING" 2>/dev/null; then
        stop_spinner
        warn "gh-proxy.com failed, trying directly..."
        start_spinner "Downloading keyring from cli.github.com"
        curl -fsSL "https://cli.github.com/packages/githubcli-archive-keyring.gpg" -o "$GPG_KEYRING" || fail "Failed to download GitHub CLI keyring."
    fi
    stop_spinner
    chmod go+r "$GPG_KEYRING"

    echo "deb [arch=$(dpkg --print-architecture) signed-by=$GPG_KEYRING] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

    log "Updating package index and installing gh..."
    start_spinner "Installing gh via apt"
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq gh
    stop_spinner

    GH_VERSION=$(gh --version | head -1 | awk '{print $3}')
    ok "GitHub CLI $GH_VERSION installed."
else
    warn "GitHub CLI already installed, skipping."
fi

# ──────────────────────────────────────────────
# 9. Rust (rustup + stable toolchain + crates mirror)
# ──────────────────────────────────────────────
next_step "Installing Rust toolchain (USTC mirror)"

RUSTUP_HOME="/usr/local/share/rustup"
CARGO_HOME="/usr/local/share/cargo"

if ! command_exists rustc; then
    log "Installing rustup + Rust stable via USTC mirror..."
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"

    start_spinner "Downloading and installing Rust stable"
    RUSTUP_HOME="$RUSTUP_HOME" CARGO_HOME="$CARGO_HOME" \
        RUSTUP_DIST_SERVER="https://mirrors.ustc.edu.cn/rust-static" \
        RUSTUP_UPDATE_ROOT="https://mirrors.ustc.edu.cn/rust-static/rustup" \
        curl -fsSL https://sh.rustup.rs | \
        RUSTUP_HOME="$RUSTUP_HOME" CARGO_HOME="$CARGO_HOME" \
        RUSTUP_DIST_SERVER="https://mirrors.ustc.edu.cn/rust-static" \
        RUSTUP_UPDATE_ROOT="https://mirrors.ustc.edu.cn/rust-static/rustup" \
        sh -s -- -y --no-modify-path 2>/dev/null || fail "Failed to install Rust."
    stop_spinner

    export RUSTUP_HOME="$RUSTUP_HOME"
    export CARGO_HOME="$CARGO_HOME"
    export PATH="$CARGO_HOME/bin:$PATH"

    ln -sf "$CARGO_HOME/bin/rustc" /usr/local/bin/rustc 2>/dev/null || true
    ln -sf "$CARGO_HOME/bin/cargo" /usr/local/bin/cargo 2>/dev/null || true
    ln -sf "$CARGO_HOME/bin/rustup" /usr/local/bin/rustup 2>/dev/null || true

    RUST_VERSION=$(rustc --version 2>/dev/null | awk '{print $2}')
    ok "Rust $RUST_VERSION installed."
else
    warn "Rust already installed, skipping."
fi

log "Configuring Rust for zsh..."
RUST_BLOCK="$CURRENT_USER_HOME/.zsh_rust"
if [[ -f "$RUST_BLOCK" ]] && grep -q "zsh_rust" "$ZSHRC" 2>/dev/null; then
    warn "Rust zsh config already exists, skipping."
else
    cat > "$RUST_BLOCK" <<'EOF'
export RUSTUP_HOME="/usr/local/share/rustup"
export CARGO_HOME="/usr/local/share/cargo"
export RUSTUP_DIST_SERVER="https://mirrors.ustc.edu.cn/rust-static"
export RUSTUP_UPDATE_ROOT="https://mirrors.ustc.edu.cn/rust-static/rustup"
export PATH="$CARGO_HOME/bin:$PATH"
EOF
    chown "$CURRENT_USER:$CURRENT_USER" "$RUST_BLOCK"

    if ! grep -q "zsh_rust" "$ZSHRC" 2>/dev/null; then
        echo '' >> "$ZSHRC"
        echo 'source $HOME/.zsh_rust' >> "$ZSHRC"
        chown "$CURRENT_USER:$CURRENT_USER" "$ZSHRC"
    fi
    source "$CURRENT_USER_HOME/.zsh_rust" 2>/dev/null || true
    ok "Rust zsh config written."
fi

log "Configuring cargo crates.io mirror (USTC)..."
CARGO_CONFIG="$CARGO_HOME/config.toml"
mkdir -p "$CARGO_HOME"
if grep -q "mirrors.ustc.edu.cn" "$CARGO_CONFIG" 2>/dev/null; then
    warn "cargo mirror already configured, skipping."
else
    cat > "$CARGO_CONFIG" <<EOF
[source.crates-io]
replace-with = "ustc"

[source.ustc]
registry = "https://mirrors.ustc.edu.cn/crates.io-index"
EOF
    chmod 644 "$CARGO_CONFIG"
    ok "cargo mirror configured to USTC."
fi

ok "Rust $(rustc --version 2>/dev/null | awk '{print $2}') + USTC mirror configured."

# ──────────────────────────────────────────────
# 10. Go (golang + GOPROXY mirror)
# ──────────────────────────────────────────────
next_step "Installing Go (GOPROXY.cn mirror)"

GO_VERSION="1.24.3"
GO_DIR="/usr/local/go"
GO_TARBALL="go${GO_VERSION}.linux-amd64.tar.gz"

if ! command_exists go; then
    log "Downloading Go ${GO_VERSION}..."
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch* | armv8*) GO_TARBALL="go${GO_VERSION}.linux-arm64.tar.gz" ;;
        armv7*) GO_TARBALL="go${GO_VERSION}.linux-armv6l.tar.gz" ;;
        *) GO_TARBALL="go${GO_VERSION}.linux-amd64.tar.gz" ;;
    esac

    GO_DL_URL="https://dl.google.com/go/${GO_TARBALL}"
    GO_MIRROR_URL="https://mirrors.ustc.edu.cn/golang/${GO_TARBALL}"

    GO_TMP=$(mktemp -d)
    start_spinner "Downloading Go $GO_VERSION"
    if ! curl --progress-bar --fail -L "$GO_MIRROR_URL" -o "$GO_TMP/go.tar.gz" 2>/dev/null; then
        stop_spinner
        warn "USTC mirror failed, trying dl.google.com..."
        start_spinner "Downloading Go from dl.google.com"
        curl --progress-bar --fail -L "$GO_DL_URL" -o "$GO_TMP/go.tar.gz" || fail "Failed to download Go."
    fi
    stop_spinner

    rm -rf "$GO_DIR"
    tar -C /usr/local -xzf "$GO_TMP/go.tar.gz"
    rm -rf "$GO_TMP"

    ln -sf "$GO_DIR/bin/go" /usr/local/bin/go 2>/dev/null || true
    ln -sf "$GO_DIR/bin/gofmt" /usr/local/bin/gofmt 2>/dev/null || true

    GO_VER=$(go version | awk '{print $3}')
    ok "Go $GO_VER installed."
else
    warn "Go already installed, skipping."
fi

log "Configuring Go for zsh..."
GO_BLOCK="$CURRENT_USER_HOME/.zsh_go"
if [[ -f "$GO_BLOCK" ]] && grep -q "zsh_go" "$ZSHRC" 2>/dev/null; then
    warn "Go zsh config already exists, skipping."
else
    cat > "$GO_BLOCK" <<'EOF'
export GOPATH="$HOME/go"
export GOBIN="$GOPATH/bin"
export PATH="/usr/local/go/bin:$GOBIN:$PATH"
export GOPROXY=https://goproxy.cn,direct
export GOSUMDB=sum.golang.google.cn
EOF
    chown "$CURRENT_USER:$CURRENT_USER" "$GO_BLOCK"

    if ! grep -q "zsh_go" "$ZSHRC" 2>/dev/null; then
        echo '' >> "$ZSHRC"
        echo 'source $HOME/.zsh_go' >> "$ZSHRC"
        chown "$CURRENT_USER:$CURRENT_USER" "$ZSHRC"
    fi
    source "$CURRENT_USER_HOME/.zsh_go" 2>/dev/null || true
    ok "Go zsh config written."
fi

export GOPATH="$HOME/go"
export GOBIN="$GOPATH/bin"
export PATH="/usr/local/go/bin:$GOBIN:$PATH"
export GOPROXY=https://goproxy.cn,direct

go env -w GOPROXY=https://goproxy.cn,direct
go env -w GOSUMDB=sum.golang.google.cn

ok "Go $(go version 2>/dev/null | awk '{print $3}') + goproxy.cn configured."

# ──────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────
SCRIPT_END=$(date +%s)
SCRIPT_TOTAL=$(( SCRIPT_END - SCRIPT_START ))

echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  All done! (${SCRIPT_TOTAL}s) System initialization completed.  ${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "${CYAN}  Node.js:${NC}  $(node -v)"
echo -e "${CYAN}  npm:${NC}      $(npm -v)"
echo -e "${CYAN}  Bun:${NC}      $(bun -v 2>/dev/null || echo 'run source /etc/profile.d/bun.sh first')"
echo -e "${CYAN}  Python:${NC}   $(python3 --version)"
echo -e "${CYAN}  pip:${NC}      $(pip3 --version | awk '{print $2}')"
echo -e "${CYAN}  uv:${NC}       $(uv --version 2>/dev/null | awk '{print $2}' || echo 'not found')"
echo -e "${CYAN}  gh:${NC}       $(gh --version 2>/dev/null | awk '{print $3}' | head -1 || echo 'not found')"
echo -e "${CYAN}  Rust:${NC}     $(rustc --version 2>/dev/null | awk '{print $2}' || echo 'not found')"
echo -e "${CYAN}  Go:${NC}       $(go version 2>/dev/null | awk '{print $3}' || echo 'not found')"
echo -e "${CYAN}  Zsh:${NC}      $(zsh --version)"
echo -e "${CYAN}  Shell:${NC}    zsh (for user $CURRENT_USER)"
echo ""
echo -e "${YELLOW}  Log file: $LOG_FILE${NC}"
echo -e "${YELLOW}  Run 'source ~/.zshrc' or open a new terminal to load the environment.${NC}"
echo ""
