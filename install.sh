#!/usr/bin/env bash
# AstroHome one-shot installer.
#
# Remote (one-line via curl|bash; see docs/install-curl.md for hosting setup):
#   curl -fsSL https://raw.githubusercontent.com/<you>/astrohome-install/main/install.sh | bash
# It will prompt for GH_TOKEN and ASTROHOME_OWNER, then clone the private main repo.
#
# Local (inside an existing checkout):
#   bash install.sh
#
# Env:
#   GH_TOKEN              GitHub PAT with Contents:Read on the repo
#   ASTROHOME_OWNER       GitHub user or org owning the repo
#   ASTROHOME_REPO        explicit git URL (overrides token-derived URL)
#   ASTROHOME_DIR         install dir (default: $HOME/astrohome)
#   ASTROHOME_BRANCH      branch (default: main)
#   ASTROHOME_DOMAIN      Cloudflare domain for tunnel (skips prompt)
#   ASTROHOME_TUNNEL_TOKEN  use token-mode tunnel (skip cloudflared login flow)
#   ASTROHOME_RESTORE_FROM  restore data during install: a .db snapshot, a
#                           whatsapp-auth-*.tar.gz, a previous install's data/
#                           directory, or an https:// URL to one of those
#   ASTROHOME_SKIP_RESTORE=1 skip the restore prompt (fresh data)
#
# Uninstall (also works via the curl one-liner):
#   bash install.sh --uninstall [--purge]
#   ASTROHOME_SKIP_TUNNEL=1, ASTROHOME_SKIP_SERVICES=1, ASTROHOME_NONINTERACTIVE=1

set -euo pipefail

ASTROHOME_INSTALLER_VERSION="0.2.0"
ASTROHOME_DIR_PRESET="${ASTROHOME_DIR:+1}"
ASTROHOME_DIR="${ASTROHOME_DIR:-$HOME/astrohome}"
ASTROHOME_REPO="${ASTROHOME_REPO:-}"
ASTROHOME_REPO_NAME="${ASTROHOME_REPO_NAME:-astrohome-core}"
ASTROHOME_BRANCH="${ASTROHOME_BRANCH:-main}"
NODE_VERSION="22.22.1"

TAG=install
# When running via curl|bash the script isn't on disk yet; _common.sh is
# sourced only after the repo is cloned, so define minimal helpers inline.
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$TAG" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$TAG" "$*" >&2; }
die()  { printf '\033[1;31m[%s]\033[0m %s\n' "$TAG" "$*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { have_cmd "$1" || die "missing required command: $1"; }

# apt/dpkg steps need root. On a root shell (typical fresh cloud box) run them
# directly; otherwise elevate with sudo.
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# Keep apt fully non-interactive: a server's needrestart/debconf otherwise pops
# a whiptail dialog (pending-kernel notice, service-restart list) that hangs the
# install waiting for a keypress.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

print_banner() {
  cat >&2 <<EOF

  ╭───────────────────────────────────────────────╮
  │  AstroHome installer  v${ASTROHOME_INSTALLER_VERSION}                  │
  │  household AI assistant — kernel + bot + CLI  │
  ╰───────────────────────────────────────────────╯

  Install dir:  $ASTROHOME_DIR
  Branch:       $ASTROHOME_BRANCH
  Skip tunnel:  ${ASTROHOME_SKIP_TUNNEL:-0}
  Skip services: ${ASTROHOME_SKIP_SERVICES:-0}

EOF
}

# Interactive prompt that works under curl|bash (stdin is the script).
prompt_tty() {
  local label="$1" secret="${2:-0}" value=""
  if [ "${ASTROHOME_NONINTERACTIVE:-0}" = 1 ]; then
    die "missing $label (non-interactive mode)"
  fi
  [ -r /dev/tty ] || die "$label needed but no tty available"
  while [ -z "$value" ]; do
    if [ "$secret" = 1 ]; then
      printf '  %s: ' "$label" > /dev/tty
      stty -echo < /dev/tty
      read -r value < /dev/tty || true
      stty echo < /dev/tty
      printf '\n' > /dev/tty
    else
      printf '  %s: ' "$label" > /dev/tty
      read -r value < /dev/tty || true
    fi
  done
  printf '%s' "$value"
}

expand_tilde() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# What lives at a candidate install path?
#   missing | empty | checkout (a git clone we can update) |
#   occupied (non-empty, not a checkout — refuse, it may be a previous
#   deployment's runtime state: .env, data/, homeassistant/ ...)
classify_dir() {
  local dir="$1"
  if [ ! -e "$dir" ]; then printf 'missing'; return; fi
  if [ -d "$dir/.git" ]; then printf 'checkout'; return; fi
  if [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then printf 'empty'; return; fi
  printf 'occupied'
}

choose_install_dir() {
  # An explicit ASTROHOME_DIR or non-interactive run keeps today's behavior;
  # the guard in clone_or_update_repo still refuses an occupied target.
  if [ -n "$ASTROHOME_DIR_PRESET" ] || [ "${ASTROHOME_NONINTERACTIVE:-0}" = 1 ]; then
    return 0
  fi
  [ -r /dev/tty ] || return 0

  while :; do
    printf '  Install directory [%s]: ' "$ASTROHOME_DIR" > /dev/tty
    local answer=""
    read -r answer < /dev/tty || true
    [ -n "$answer" ] && ASTROHOME_DIR="$(expand_tilde "$answer")"

    case "$(classify_dir "$ASTROHOME_DIR")" in
      missing|empty)
        log "installing into $ASTROHOME_DIR"
        return 0
        ;;
      checkout)
        log "existing AstroHome checkout at $ASTROHOME_DIR — it will be updated in place"
        return 0
        ;;
      occupied)
        warn "$ASTROHOME_DIR exists and is not an AstroHome checkout — not touching it."
        if [ -d "$ASTROHOME_DIR/data" ] || [ -f "$ASTROHOME_DIR/.env" ]; then
          warn "it looks like a previous deployment's runtime state. Install the code"
          warn "somewhere else (e.g. $HOME/astrohome-core), then restore its data at"
          warn "the wizard's Data step: $ASTROHOME_DIR/data"
        fi
        ASTROHOME_DIR="$HOME/astrohome-core"
        ;;
    esac
  done
}

# Browser-based setup: download the wizard from the public installer repo
# (or use the checkout's copy), serve it locally, let it drive this same
# script in engine mode. Returns 1 to fall back to the terminal wizard.
maybe_launch_gui() {
  [ "${ASTROHOME_NO_GUI:-0}" = 1 ] && return 1
  [ "${ASTROHOME_NONINTERACTIVE:-0}" = 1 ] && return 1
  [ -r /dev/tty ] || return 1

  # A local opener means a browser is on this host (desktop/laptop). None (a
  # headless cloud box) is not a dead end: we still offer the wizard and serve
  # it back to the operator's own machine, printing a reachable URL.
  local opener="" remote=0
  if [ "$OS" = macos ]; then
    opener=open
  elif have_cmd xdg-open; then
    opener=xdg-open
  fi
  [ -n "$opener" ] || remote=1

  if [ "$remote" = 1 ]; then
    printf '  Set up in a browser on your own computer, or in this terminal? [B/t]: ' > /dev/tty
  else
    printf '  Set up in your browser (recommended) or in this terminal? [B/t]: ' > /dev/tty
  fi
  local choice=""
  read -r choice < /dev/tty || true
  case "$choice" in t|T) return 1 ;; esac

  local gui_base="${ASTROHOME_GUI_BASE:-https://raw.githubusercontent.com/alome007/astrohome-installer/main}"
  local gui_dir
  gui_dir="$(mktemp -d)"
  local local_repo=""
  local script_dir
  script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
  if [ -n "$script_dir" ] && [ -f "$script_dir/scripts/install/setup-gui/server.mjs" ]; then
    local_repo="$script_dir"
  else
    log "downloading setup wizard"
    curl -fsSL "$gui_base/setup-gui/server.mjs" -o "$gui_dir/server.mjs" &&
      curl -fsSL "$gui_base/setup-gui/index.html" -o "$gui_dir/index.html" &&
      curl -fsSL "$gui_base/env.example" -o "$gui_dir/env.example" || {
      warn "wizard download failed — continuing in the terminal"
      return 1
    }
  fi

  # How the wizard is reached. On a desktop it binds loopback and opens the
  # browser. On a headless box it can't open anything, so it prints the URL and
  # we tell the operator how to reach it — securely over an SSH tunnel by
  # default, or on the public IP with ASTROHOME_GUI_PUBLIC=1 (plain HTTP, so the
  # keys entered cross the network unencrypted — only on a trusted network).
  local gui_flags=() port="${ASTROHOME_GUI_PORT:-8423}"
  gui_flags+=(--port "$port")
  if [ "$remote" = 1 ]; then
    gui_flags+=(--no-open)
    local ip
    ip="$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $3}')"
    [ -n "$ip" ] || ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$ip" ] || ip="<this-server-ip>"
    if [ "${ASTROHOME_GUI_PUBLIC:-0}" = 1 ]; then
      gui_flags+=(--host 0.0.0.0 --url-host "$ip")
      cat > /dev/tty <<EOF

  ▸ No browser on this server — the wizard will listen on the public IP.
    Open the URL that prints below on your own computer.
    ⚠  Plain HTTP: the keys you enter cross the internet unencrypted. Only use
       ASTROHOME_GUI_PUBLIC=1 on a trusted network — otherwise Ctrl-C and use
       the SSH-tunnel method (re-run without ASTROHOME_GUI_PUBLIC).
    If port $port is firewalled, use the SSH-tunnel method instead.

EOF
    else
      cat > /dev/tty <<EOF

  ▸ No browser on this server — reach the wizard securely over SSH:
      1) On your own computer, run:
           ssh -L $port:localhost:$port root@$ip
      2) Leave it open, then open the URL that prints below (it starts with
         http://127.0.0.1:$port/) in your browser.
    (To serve it on the public IP instead — less secure, plain HTTP — Ctrl-C
     and re-run with ASTROHOME_GUI_PUBLIC=1.)

EOF
    fi
  fi

  log "setup wizard starting (Ctrl-C here to abort)"
  local rc=0
  if [ -n "$local_repo" ]; then
    node "$local_repo/scripts/install/setup-gui/server.mjs" --local-repo "$local_repo" "${gui_flags[@]}" || rc=$?
  else
    node "$gui_dir/server.mjs" --base "$gui_base" "${gui_flags[@]}" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    die "the setup wizard reported a failed install — the browser log has details; re-run to resume (completed work is reused)"
  fi
  return 0
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    *)      die "unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64)        ARCH=x64   ;;
    *)             die "unsupported arch: $(uname -m) (32-bit Pi not supported)" ;;
  esac
  log "platform: $OS-$ARCH"
}

preflight() {
  for c in git curl bash openssl; do need_cmd "$c"; done
  if [ "$OS" = linux ] && ! have_cmd apt-get; then
    die "Linux target requires Debian/Ubuntu (apt-get). Raspberry Pi OS works."
  fi
}

# fnm is installed with --skip-shell (so it doesn't rewrite the profile mid-run),
# which leaves an interactive shell with no `node` — and the `astrohome` CLI's
# `#!/usr/bin/env node` then can't resolve. Add fnm to the profile so new shells
# (and the CLI) find node.
setup_shell_path() {
  local rcs shell_name
  if [ "$OS" = macos ]; then
    rcs="$HOME/.zshrc $HOME/.profile"
    shell_name=zsh
  else
    rcs="$HOME/.bashrc $HOME/.profile"
    shell_name=bash
  fi
  local block
  block="# >>> astrohome fnm >>>
export PATH=\"\$HOME/.local/share/fnm:\$HOME/Library/Application Support/fnm:\$PATH\"
eval \"\$(fnm env --shell $shell_name 2>/dev/null)\"
# <<< astrohome fnm <<<"
  local rc
  for rc in $rcs; do
    [ -e "$rc" ] || touch "$rc"
    grep -q "astrohome fnm" "$rc" 2>/dev/null || printf '\n%s\n' "$block" >> "$rc"
  done
  log "added fnm to the shell profile (node + astrohome CLI available in new shells)"
}

install_runtime() {
  if ! have_cmd fnm; then
    # fnm's installer unzips its release; minimal server images (a fresh cloud
    # VM) ship without unzip, which aborts the install — ensure it first.
    if [ "$OS" = linux ] && ! have_cmd unzip; then
      log "installing unzip (fnm needs it)"
      $SUDO apt-get update -qq && $SUDO apt-get install -y unzip
    fi
    log "installing fnm"
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
  fi
  export PATH="$HOME/.local/share/fnm:$HOME/Library/Application Support/fnm:$PATH"
  eval "$(fnm env --shell bash 2>/dev/null)"

  log "installing Node $NODE_VERSION"
  fnm install "$NODE_VERSION"
  fnm default "$NODE_VERSION"
  fnm use     "$NODE_VERSION"
  need_cmd node
  need_cmd npm

  log "activating pnpm"
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  if corepack enable 2>/dev/null && corepack prepare pnpm@9.15.0 --activate 2>/dev/null; then
    log "pnpm activated via corepack"
  else
    warn "corepack failed — falling back to npm install -g pnpm@9.15.0"
    npm install -g pnpm@9.15.0
  fi
  have_cmd pnpm || die "pnpm installation failed"
  log "pnpm $(pnpm --version)"

  setup_shell_path
}

install_support_tools() {
  local need=()
  have_cmd cloudflared || need+=(cloudflared)
  have_cmd jq          || need+=(jq)
  # gh enables token-free `gh auth login`; only pull it when no token was given.
  if [ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    have_cmd gh || need+=(gh)
  fi
  [ "${#need[@]}" -gt 0 ] || return 0

  log "installing: ${need[*]}"
  if [ "$OS" = macos ]; then
    have_cmd brew || die "Homebrew not found. Install from https://brew.sh and re-run."
    brew install "${need[@]}"
    return
  fi

  local deb_arch
  case "$ARCH" in
    arm64) deb_arch=arm64 ;;
    x64)   deb_arch=amd64 ;;
  esac
  for pkg in "${need[@]}"; do
    case "$pkg" in
      cloudflared)
        local tmp; tmp="$(mktemp --suffix=.deb)"
        curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${deb_arch}.deb" -o "$tmp"
        $SUDO dpkg -i "$tmp"
        rm -f "$tmp"
        ;;
      jq)
        $SUDO apt-get update -qq && $SUDO apt-get install -y jq
        ;;
      gh)
        # GitHub CLI via the official apt repo (enables token-free `gh auth login`).
        $SUDO mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
        $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=${deb_arch} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
          | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        $SUDO apt-get update -qq && $SUDO apt-get install -y gh
        ;;
    esac
  done
}

clone_or_update_repo() {
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local gh_authed=0

  if [ "$(classify_dir "$ASTROHOME_DIR")" = occupied ]; then
    die "$ASTROHOME_DIR exists and is not an AstroHome checkout — pick another
  directory (ASTROHOME_DIR=<path>) rather than overwriting what's there. If it
  holds a previous deployment's data/, restore it during install with
  ASTROHOME_RESTORE_FROM=$ASTROHOME_DIR/data"
  fi

  # Token-free path: with no token supplied and the GitHub CLI present, offer
  # `gh auth login` (a device/web flow — nothing to create or paste) and wire
  # git's credential helper so clone/fetch work over HTTPS without a token.
  if [ -z "$token" ] && have_cmd gh; then
    if ! gh auth status >/dev/null 2>&1; then
      if [ "${ASTROHOME_NONINTERACTIVE:-0}" != 1 ] && [ -r /dev/tty ]; then
        printf '  Authenticate with GitHub CLI now (browser/device login, no token to paste)? [Y/n]: ' > /dev/tty
        local gh_ans=""
        read -r gh_ans < /dev/tty || true
        case "$gh_ans" in
          n|N) : ;;
          *) gh auth login --hostname github.com --git-protocol https --web < /dev/tty ||
               warn "gh auth login did not complete — falling back to a token" ;;
        esac
      fi
    fi
    if gh auth status >/dev/null 2>&1; then
      gh auth setup-git >/dev/null 2>&1 || true
      gh_authed=1
      [ -n "${ASTROHOME_OWNER:-}" ] || ASTROHOME_OWNER="$(gh api user --jq .login 2>/dev/null || true)"
      log "authenticated via GitHub CLI (gh) — no token needed"
    fi
  fi

  if [ -d "$ASTROHOME_DIR/.git" ]; then
    log "updating $ASTROHOME_DIR"
    if [ "$gh_authed" = 1 ]; then
      git -C "$ASTROHOME_DIR" fetch --quiet origin "$ASTROHOME_BRANCH" ||
        die "git fetch failed — check 'gh auth status' and that the account can read the repo"
    else
      local origin_url fetch_url="origin"
      origin_url="$(git -C "$ASTROHOME_DIR" remote get-url origin 2>/dev/null || true)"
      # GitHub's git-over-HTTPS rejects `Authorization: Bearer <PAT>` with
      # "invalid credentials" — the token must ride as basic-auth. Use the same
      # URL-embedded x-access-token form the clone path uses; fetch from it
      # directly so the token is never persisted into the remote. Prompt for a
      # token here too (the update path used to only read $GH_TOKEN, so a
      # re-run on an existing checkout silently had no credentials).
      if [[ "$origin_url" == https://github.com/* ]]; then
        if [ -z "$token" ]; then
          log "a GitHub token is needed to update this private checkout"
          token="$(prompt_tty 'GitHub token (hidden)' 1)"
        fi
        fetch_url="${origin_url/https:\/\//https://x-access-token:${token}@}"
      fi
      git -C "$ASTROHOME_DIR" fetch --quiet "$fetch_url" "$ASTROHOME_BRANCH" ||
        die "git fetch failed — the token may be expired or lack Contents:Read on the repo. Regenerate at https://github.com/settings/personal-access-tokens"
    fi
    git -C "$ASTROHOME_DIR" checkout --quiet "$ASTROHOME_BRANCH"
    git -C "$ASTROHOME_DIR" merge --ff-only FETCH_HEAD
    return
  fi

  local owner="${ASTROHOME_OWNER:-}"

  # gh-authenticated clone: git uses the gh credential helper, no token embedded.
  if [ "$gh_authed" = 1 ] && [ -z "$ASTROHOME_REPO" ]; then
    [ -n "$owner" ] || owner="$(prompt_tty 'GitHub owner (user or org)')"
    ASTROHOME_REPO="https://github.com/${owner}/${ASTROHOME_REPO_NAME}.git"
  fi

  if [ -z "$ASTROHOME_REPO" ]; then
    log "this repo is private — a GitHub token is needed to clone it"
    log "create one at https://github.com/settings/personal-access-tokens"
    log "(fine-grained, repo access: astrohome, permissions: Contents → Read-only)"
    [ -n "$owner" ] || owner="$(prompt_tty 'GitHub owner (user or org)')"
    [ -n "$token" ] || token="$(prompt_tty 'GitHub token (hidden)' 1)"
    ASTROHOME_REPO="https://github.com/${owner}/${ASTROHOME_REPO_NAME}.git"

    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $token" \
      "https://api.github.com/repos/${owner}/${ASTROHOME_REPO_NAME}")"
    case "$http_code" in
      200) log "token verified — repo accessible" ;;
      401) die "token rejected (HTTP 401) — check the value, regenerate if needed" ;;
      403) die "token forbidden (HTTP 403) — SSO authorization may be required" ;;
      404) die "repo not visible to token (HTTP 404) — add ${owner}/${ASTROHOME_REPO_NAME} to the token's Selected Repositories" ;;
      *)   die "unexpected HTTP $http_code from github api" ;;
    esac
  fi

  log "cloning $ASTROHOME_REPO"
  if [ "$gh_authed" = 1 ]; then
    git clone --branch "$ASTROHOME_BRANCH" "$ASTROHOME_REPO" "$ASTROHOME_DIR"
  elif [ -n "$token" ] && [[ "$ASTROHOME_REPO" == https://* ]]; then
    local authed_url="${ASTROHOME_REPO/https:\/\//https://x-access-token:${token}@}"
    git clone --branch "$ASTROHOME_BRANCH" "$authed_url" "$ASTROHOME_DIR"
    git -C "$ASTROHOME_DIR" remote set-url origin "$ASTROHOME_REPO"
    warn "token not persisted — for 'astrohome-update' later, run:"
    warn "  cd $ASTROHOME_DIR && gh auth setup-git    (or switch origin to SSH)"
  else
    git clone --branch "$ASTROHOME_BRANCH" "$ASTROHOME_REPO" "$ASTROHOME_DIR"
  fi
}

run_step() {
  local label="$1"; shift
  local start
  start="$(date +%s)"
  printf '\033[1;34m[%s]\033[0m %-42s' "$TAG" "$label" >&2
  if "$@" >> "$INSTALL_LOG" 2>&1; then
    printf '\033[1;32m✓\033[0m %ss\n' "$(($(date +%s) - start))" >&2
    return 0
  fi
  local rc=$?
  printf '\033[1;31m✗\033[0m\n' >&2
  warn "step failed — last 30 log lines:"
  tail -30 "$INSTALL_LOG" >&2 || true
  warn "full log: $INSTALL_LOG"
  return "$rc"
}

build_repo() {
  cd "$ASTROHOME_DIR"
  INSTALL_LOG="$ASTROHOME_DIR/data/install.log"
  mkdir -p "$(dirname "$INSTALL_LOG")"
  : > "$INSTALL_LOG"
  log "build log: $INSTALL_LOG"

  # pnpm respects NODE_ENV at install time. If the caller's shell has
  # NODE_ENV=production exported (common in .zshrc/.bashrc on prod hosts),
  # devDependencies like typescript/tsx/lefthook get skipped and the build
  # then dies with `tsc: command not found`. Force-unset for the install.
  unset NODE_ENV

  run_step "installing dependencies"   pnpm install --frozen-lockfile               || die "pnpm install failed"
  run_step "compiling TypeScript"      pnpm build                                   || die "pnpm build failed"
  # Download the ML models to the SAME path the kernel reads at boot
  # ($ASTROHOME_DIR/data/models). Without this, setup:models runs with cwd
  # packages/kernel and writes to packages/kernel/data/models, which the
  # kernel never looks at — so it re-downloads the 97MB model on first boot,
  # adding minutes. ASTROHOME_MODELS_DIR is honored by download-models.ts;
  # it only affects this build step (the kernel service reads its own .env).
  export ASTROHOME_MODELS_DIR="$ASTROHOME_DIR/data/models"
  run_step "downloading ML models"     pnpm --filter @astrohome/kernel setup:models || die "model download failed"
  unset ASTROHOME_MODELS_DIR

  if run_step "building web client"    pnpm --filter @astrohome/web build; then
    :
  else
    warn "web build failed — kernel will run but /app/ will 404 (see $INSTALL_LOG)"
    WEB_BUILD_FAILED=1
  fi

  for f in packages/kernel/dist/boot.js \
           packages/clients/whatsapp/dist/bot.js \
           packages/clients/cli/dist/cli.js; do
    [ -f "$ASTROHOME_DIR/$f" ] || die "build artifact missing: $f (see $INSTALL_LOG)"
  done
  log "build artifacts verified"
}

run_subscript() {
  local name="$1"; shift
  local path="$ASTROHOME_DIR/scripts/install/$name"
  [ -f "$path" ] || die "missing $path (is your checkout up to date?)"
  bash "$path" "$@"
}

install_fcm_credentials() {
  [ -n "${ASTROHOME_FCM_JSON_FILE:-}" ] || return 0
  if [ ! -f "$ASTROHOME_FCM_JSON_FILE" ]; then
    warn "ASTROHOME_FCM_JSON_FILE set but not found: $ASTROHOME_FCM_JSON_FILE — skipping FCM"
    return 0
  fi
  local dest="$ASTROHOME_DIR/config/secrets/fcm-service-account.json"
  mkdir -p "$(dirname "$dest")"
  install -m 600 "$ASTROHOME_FCM_JSON_FILE" "$dest"
  # Pin the absolute path so the kernel finds it regardless of its working dir.
  local env_file="$ASTROHOME_DIR/.env" tmp
  if [ -f "$env_file" ]; then
    tmp="$(mktemp)"
    grep -v '^FCM_SERVICE_ACCOUNT_PATH=' "$env_file" > "$tmp" 2>/dev/null || true
    printf 'FCM_SERVICE_ACCOUNT_PATH=%s\n' "$dest" >> "$tmp"
    cat "$tmp" > "$env_file"
    rm -f "$tmp"
  fi
  log "installed Firebase service-account.json → $dest"
}

configure_data_restore() {
  if [ "${ASTROHOME_SKIP_RESTORE:-0}" = 1 ]; then
    log "data restore skipped (ASTROHOME_SKIP_RESTORE=1) — starting fresh"
    return 0
  fi

  if [ -n "${ASTROHOME_RESTORE_FROM:-}" ]; then
    run_subscript restore-data.sh "$ASTROHOME_DIR" "$ASTROHOME_RESTORE_FROM"
    return $?
  fi

  if [ "${ASTROHOME_NONINTERACTIVE:-0}" = 1 ]; then
    log "non-interactive mode + no ASTROHOME_RESTORE_FROM — starting fresh"
    return 0
  fi

  cat >&2 <<EOF

  ▸ Data
    Start fresh, or restore Astro's memory from a backup? Accepted sources:
      • a snapshot            data/backups/astrohome-YYYY-MM-DD.db
      • a WhatsApp archive    whatsapp-auth-*.tar.gz
      • a previous install's  data/ directory (or its backups/ directory)
      • an https:// URL to any of the above

EOF
  local choice
  printf '  Restore from a backup? [y/N]: ' >&2
  read -r choice </dev/tty || choice="n"
  case "$choice" in
    y|Y|yes)
      local src
      src="$(prompt_tty 'Backup path or https URL')"
      if run_subscript restore-data.sh "$ASTROHOME_DIR" "$src"; then
        return 0
      fi
      warn "restore failed — fix the source and re-run later with:"
      warn "  bash $ASTROHOME_DIR/scripts/install/restore-data.sh $ASTROHOME_DIR <source>"
      printf '  Continue installing with fresh data? [Y/n]: ' >&2
      read -r choice </dev/tty || choice="y"
      case "$choice" in n|N|no) die "install aborted at restore step" ;; esac
      ;;
    *)
      log "starting fresh — restore any time later with scripts/install/restore-data.sh"
      ;;
  esac
}

print_tunnel_help() {
  cat <<EOF >&2

  Cloudflare Tunnel makes your kernel reachable on the public internet via
  HTTPS without opening any ports on your router. It's free and you keep
  control: traffic terminates on Cloudflare, then is forwarded over an
  outbound-only connection to your kernel.

  You'll need:
    • A domain you control, added to your Cloudflare account
      (Cloudflare can transfer most domains in ~5 minutes)
    • A graphical browser to authorize cloudflared (one-time step;
      can be done from any machine logged into the same Cloudflare
      account, then cert.pem copied to this host)
    • Or a tunnel token (Cloudflare dashboard → Zero Trust → Networks →
      Tunnels → Create), passed via ASTROHOME_TUNNEL_TOKEN

  Skip this step now and re-run later with:
    bash $ASTROHOME_DIR/scripts/install/setup-tunnel.sh $ASTROHOME_DIR

EOF
}

# Poll the kernel's health endpoint on its chosen port until it answers.
# The gateway binds LAST in boot (after migrations, embeddings, and every
# plugin), so first boot can take a couple of minutes — we do not call the
# install a success until the URL actually responds. Returns 0 when live,
# 1 on timeout. Tunable via ASTROHOME_KERNEL_WAIT (number of 5s intervals).
verify_kernel_live() {
  local port health i=0 max="${ASTROHOME_KERNEL_WAIT:-72}"
  port="$(awk -F= '/^ASTROHOME_GATEWAY_PORT=/{print $2; exit}' "$ASTROHOME_DIR/.env" 2>/dev/null || true)"
  port="${port:-8420}"
  health="http://127.0.0.1:$port/api/v1/health"
  log "waiting for the kernel to answer at $health"
  log "  first boot fetches ML models + loads plugins — up to $((max * 5 / 60)) min"
  while [ "$i" -lt "$max" ]; do
    if curl -fsS -o /dev/null -m 5 "$health" 2>/dev/null; then
      log "✓ kernel is live — http://localhost:$port"
      return 0
    fi
    sleep 5
    i=$((i + 1))
    if [ $((i % 6)) -eq 0 ]; then log "  still booting… ($((i * 5))s elapsed)"; fi
  done
  return 1
}

verify_tunnel_live() {
  local public_url
  public_url="$(awk -F= '/^WEB_BASE_URL=/{sub(/^WEB_BASE_URL=/,""); print; exit}' "$ASTROHOME_DIR/.env" 2>/dev/null || true)"
  if [ -z "$public_url" ]; then
    warn "no WEB_BASE_URL in .env — skipping tunnel verification"
    return 0
  fi
  log "verifying tunnel at $public_url (waiting up to 60s)"
  local i=0
  while [ "$i" -lt 12 ]; do
    if curl -fsS -o /dev/null -m 5 "$public_url/api/v1/health" 2>/dev/null; then
      log "✓ tunnel live: $public_url"
      return 0
    fi
    sleep 5
    i=$((i+1))
  done
  warn "tunnel did not respond at $public_url/api/v1/health within 60s"
  warn "check: astrohome service logs --service tunnel"
  warn "       astrohome service status"
  return 1
}

configure_remote_access() {
  if [ "${ASTROHOME_SKIP_TUNNEL:-0}" = 1 ]; then
    local kp
    kp="$(awk -F= '/^ASTROHOME_GATEWAY_PORT=/{print $2; exit}' "$ASTROHOME_DIR/.env" 2>/dev/null || true)"
    log "remote access skipped (ASTROHOME_SKIP_TUNNEL=1) — kernel will only be reachable on localhost:${kp:-8420}"
    return 0
  fi

  # A public-IP box with its own domain: terminate TLS on the box with Caddy +
  # Let's Encrypt instead of a tunnel.
  if [ -n "${ASTROHOME_CADDY_DOMAIN:-}" ]; then
    run_subscript setup-caddy.sh "$ASTROHOME_DIR"
    return $?
  fi

  if [ "${ASTROHOME_NONINTERACTIVE:-0}" = 1 ]; then
    if [ -n "${ASTROHOME_DOMAIN:-}" ] || [ -n "${ASTROHOME_TUNNEL_TOKEN:-}" ]; then
      run_subscript setup-tunnel.sh "$ASTROHOME_DIR"
      return $?
    fi
    log "non-interactive mode + no ASTROHOME_DOMAIN/ASTROHOME_TUNNEL_TOKEN — skipping tunnel"
    return 0
  fi

  cat >&2 <<EOF

  ▸ Remote access via Cloudflare Tunnel
    Mobile clients and WhatsApp need a public HTTPS URL to reach your
    kernel. Cloudflare Tunnel is free and requires no router config.

EOF
  local choice
  printf '  Set up Cloudflare Tunnel now? [y/N/help]: ' >&2
  read -r choice </dev/tty || choice="n"
  case "$choice" in
    y|Y|yes)
      run_subscript setup-tunnel.sh "$ASTROHOME_DIR"
      ;;
    h|H|help)
      print_tunnel_help
      configure_remote_access
      ;;
    *)
      warn "skipped tunnel setup — re-run with:"
      warn "  bash $ASTROHOME_DIR/scripts/install/setup-tunnel.sh $ASTROHOME_DIR"
      ;;
  esac
}

print_summary() {
  local public_url health_url kernel_port local_url
  kernel_port="$(awk -F= '/^ASTROHOME_GATEWAY_PORT=/{print $2; exit}' "$ASTROHOME_DIR/.env" 2>/dev/null || true)"
  kernel_port="${kernel_port:-8420}"
  local_url="http://localhost:$kernel_port"
  public_url="$(awk -F= '/^WEB_BASE_URL=/{sub(/^WEB_BASE_URL=/,""); print; exit}' "$ASTROHOME_DIR/.env" 2>/dev/null || true)"
  if [ -n "$public_url" ]; then
    health_url="$public_url/api/v1/health"
  else
    public_url="(none — local-only install; re-run setup-tunnel.sh to expose publicly)"
    health_url="$local_url/api/v1/health"
  fi
  cat <<EOF

───────────────────────────────────────────────────────────────
  AstroHome installed at $ASTROHOME_DIR
───────────────────────────────────────────────────────────────
  Kernel:        $local_url
  Public URL:    $public_url
  Health:        $health_url
  CLI:           astrohome --help
  Service ctl:   astrohome service [start|stop|restart|status|logs]
  Edit config:   astrohome env             (browser GUI; or: env edit|set|get|list)
                 saves .env and restarts the kernel to apply
  Skills:        astrohome skills install <owner/repo#path | url | path>
                 (also: skills list|uninstall|update — like a skill marketplace)
  Logs:          $ASTROHOME_DIR/data/logs/  (or: astrohome service logs)
  Update:        astrohome-update           (snapshots DB + WhatsApp auth first)
  Restore data:  bash $ASTROHOME_DIR/scripts/install/restore-data.sh $ASTROHOME_DIR <snapshot|dir|url>
                 (stop services first; current data is kept aside, never deleted)
  Uninstall:     astrohome uninstall        (--purge also deletes data, after a
                 final DB snapshot to ~; or run scripts/uninstall.sh directly)

  Next steps:
    • WhatsApp pairing:     astrohome service logs --service whatsapp -f
    • Log in to the CLI:    astrohome login
    • Confirm running:      astrohome service status
    • Mobile app config:    point KERNEL_URL at $public_url
                            (or use Firebase Remote Config — see docs/mobile-setup.md)
    • Connect Home Assistant (if you run HA at home, over Tailscale):
                            astrohome setup ha
EOF
  if [ "${WEB_BUILD_FAILED:-0}" = 1 ]; then
    echo "  ! Web UI build failed — investigate before reporting install complete."
  fi
  echo "───────────────────────────────────────────────────────────────"
}

main() {
  case "${1:-}" in
    --uninstall)
      shift || true
      [ -f "$ASTROHOME_DIR/scripts/uninstall.sh" ] ||
        die "no AstroHome install found at $ASTROHOME_DIR (set ASTROHOME_DIR=<path> if it lives elsewhere)"
      export ASTROHOME_DIR
      exec bash "$ASTROHOME_DIR/scripts/uninstall.sh" "$@"
      ;;
  esac

  detect_platform
  preflight
  install_runtime
  if maybe_launch_gui; then
    exit 0
  fi
  choose_install_dir
  print_banner
  install_support_tools
  clone_or_update_repo

  # A setup front-end (the GUI wizard) collects env values up front and
  # hands them over as a ready .env. If a .env already exists we REFUSE
  # rather than keep it: silently keeping a stale .env means the ports,
  # keys, and everything else the user just chose in the wizard are ignored
  # (this is exactly what sent the kernel to the old port after a re-install).
  # Fail fast — before the long build — with copy-paste commands to move or
  # delete the old file, then re-run.
  if [ -n "${ASTROHOME_ENV_FILE:-}" ]; then
    [ -f "$ASTROHOME_ENV_FILE" ] || die "ASTROHOME_ENV_FILE not found: $ASTROHOME_ENV_FILE"
    if [ -f "$ASTROHOME_DIR/.env" ]; then
      cat >&2 <<EOF

  ✗ $ASTROHOME_DIR/.env already exists.

    Installing over it would ignore the settings you just chose (ports,
    provider keys, and the rest). Pick one, then re-run the installer:

      • Keep a copy and use the new settings:
          mv "$ASTROHOME_DIR/.env" "$ASTROHOME_DIR/.env.backup-\$(date +%Y%m%d%H%M%S)"

      • Discard the old settings entirely:
          rm "$ASTROHOME_DIR/.env"

      • Or keep the existing config and skip the wizard:
          ASTROHOME_NO_GUI=1 bash install.sh    (leaves $ASTROHOME_DIR/.env untouched)

EOF
      die "refusing to overwrite or ignore an existing .env"
    fi
    install -m 600 "$ASTROHOME_ENV_FILE" "$ASTROHOME_DIR/.env"
    log "seeded .env from $ASTROHOME_ENV_FILE"
  fi

  build_repo

  run_subscript seed-env.sh "$ASTROHOME_DIR"
  install_fcm_credentials
  configure_data_restore
  configure_remote_access
  run_subscript link-cli.sh "$ASTROHOME_DIR"
  local kernel_ok=0
  if [ "${ASTROHOME_SKIP_SERVICES:-0}" != 1 ]; then
    if [ "$OS" = macos ]; then run_subscript services-macos.sh "$ASTROHOME_DIR"
    else                        run_subscript services-linux.sh "$ASTROHOME_DIR"
    fi
    # Don't declare success until the kernel actually answers on its port.
    verify_kernel_live || kernel_ok=1
    # Tunnel verification only makes sense after the kernel is up.
    if [ "${ASTROHOME_SKIP_TUNNEL:-0}" != 1 ] && [ -f "$HOME/.cloudflared/config.yml" ]; then
      verify_tunnel_live || true
    fi
  fi

  print_summary
  if [ "$kernel_ok" -ne 0 ]; then
    warn "the kernel did not answer on its port within the wait window."
    warn "it may still be finishing first boot — watch it with:"
    warn "  astrohome service logs --service kernel -f"
    warn "then open the kernel URL above. Re-running the installer is safe."
    exit 1
  fi
}

main "$@"
