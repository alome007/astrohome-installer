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
#   ASTROHOME_SKIP_TUNNEL=1, ASTROHOME_SKIP_SERVICES=1, ASTROHOME_NONINTERACTIVE=1

set -euo pipefail

ASTROHOME_INSTALLER_VERSION="0.1.0"
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

install_runtime() {
  if ! have_cmd fnm; then
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
}

install_support_tools() {
  local need=()
  have_cmd cloudflared || need+=(cloudflared)
  have_cmd jq          || need+=(jq)
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
        sudo dpkg -i "$tmp"
        rm -f "$tmp"
        ;;
      jq)
        sudo apt-get update -qq && sudo apt-get install -y jq
        ;;
    esac
  done
}

clone_or_update_repo() {
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

  if [ -d "$ASTROHOME_DIR/.git" ]; then
    log "updating $ASTROHOME_DIR"
    local git_env=(git -C "$ASTROHOME_DIR")
    [ -n "$token" ] && git_env+=(-c "http.extraheader=AUTHORIZATION: bearer $token")
    "${git_env[@]}" fetch --quiet origin
    "${git_env[@]}" checkout --quiet "$ASTROHOME_BRANCH"
    "${git_env[@]}" pull --ff-only origin "$ASTROHOME_BRANCH"
    return
  fi

  local owner="${ASTROHOME_OWNER:-}"
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
  if [ -n "$token" ] && [[ "$ASTROHOME_REPO" == https://* ]]; then
    local authed_url="${ASTROHOME_REPO/https:\/\//https://x-access-token:${token}@}"
    git clone --branch "$ASTROHOME_BRANCH" "$authed_url" "$ASTROHOME_DIR"
    git -C "$ASTROHOME_DIR" remote set-url origin "$ASTROHOME_REPO"
    warn "token not persisted — for 'astrohome-update' later, run:"
    warn "  cd $ASTROHOME_DIR && gh auth setup-git    (or switch origin to SSH)"
  else
    git clone --branch "$ASTROHOME_BRANCH" "$ASTROHOME_REPO" "$ASTROHOME_DIR"
  fi
}

build_repo() {
  cd "$ASTROHOME_DIR"
  log "pnpm install"
  pnpm install --frozen-lockfile
  log "pnpm build"
  pnpm build
  log "pnpm --filter @astrohome/kernel setup:models"
  pnpm --filter @astrohome/kernel setup:models
  log "pnpm --filter @astrohome/web build"
  if ! pnpm --filter @astrohome/web build; then
    warn "web build failed — kernel will run but /app/ will 404"
    WEB_BUILD_FAILED=1
  fi
  for f in packages/kernel/dist/boot.js \
           packages/clients/whatsapp/dist/bot.js \
           packages/clients/cli/dist/cli.js; do
    [ -f "$ASTROHOME_DIR/$f" ] || die "build artifact missing: $f"
  done
  log "build artifacts verified"
}

run_subscript() {
  local name="$1"; shift
  local path="$ASTROHOME_DIR/scripts/install/$name"
  [ -f "$path" ] || die "missing $path (is your checkout up to date?)"
  bash "$path" "$@"
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
    log "remote access skipped (ASTROHOME_SKIP_TUNNEL=1) — kernel will only be reachable on localhost:8420"
    return 0
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
  local public_url health_url
  public_url="$(awk -F= '/^WEB_BASE_URL=/{sub(/^WEB_BASE_URL=/,""); print; exit}' "$ASTROHOME_DIR/.env" 2>/dev/null || true)"
  if [ -n "$public_url" ]; then
    health_url="$public_url/api/v1/health"
  else
    public_url="(none — local-only install; re-run setup-tunnel.sh to expose publicly)"
    health_url="http://localhost:8420/api/v1/health"
  fi
  cat <<EOF

───────────────────────────────────────────────────────────────
  AstroHome installed at $ASTROHOME_DIR
───────────────────────────────────────────────────────────────
  Kernel:        http://localhost:8420
  Public URL:    $public_url
  Health:        $health_url
  CLI:           astrohome --help
  Service ctl:   astrohome service [start|stop|restart|status|logs]
  Logs:          $ASTROHOME_DIR/data/logs/  (or: astrohome service logs)
  Update:        astrohome-update           (snapshots DB + WhatsApp auth first)

  Next steps:
    • WhatsApp pairing:     astrohome service logs --service whatsapp -f
    • Log in to the CLI:    astrohome login
    • Confirm running:      astrohome service status
    • Mobile app config:    point KERNEL_URL at $public_url
                            (or use Firebase Remote Config — see docs/mobile-setup.md)
EOF
  if [ "${WEB_BUILD_FAILED:-0}" = 1 ]; then
    echo "  ! Web UI build failed — investigate before reporting install complete."
  fi
  echo "───────────────────────────────────────────────────────────────"
}

main() {
  print_banner
  detect_platform
  preflight
  install_runtime
  install_support_tools
  clone_or_update_repo
  build_repo

  run_subscript seed-env.sh "$ASTROHOME_DIR"
  configure_remote_access
  run_subscript link-cli.sh "$ASTROHOME_DIR"
  if [ "${ASTROHOME_SKIP_SERVICES:-0}" != 1 ]; then
    if [ "$OS" = macos ]; then run_subscript services-macos.sh "$ASTROHOME_DIR"
    else                        run_subscript services-linux.sh "$ASTROHOME_DIR"
    fi
    # Tunnel verification only makes sense after the kernel service is up.
    if [ "${ASTROHOME_SKIP_TUNNEL:-0}" != 1 ] && [ -f "$HOME/.cloudflared/config.yml" ]; then
      verify_tunnel_live || true
    fi
  fi

  print_summary
}

main "$@"
