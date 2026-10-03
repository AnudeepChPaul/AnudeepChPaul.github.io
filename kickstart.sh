#!/usr/bin/env bash
# curl -fsSL https://anudeepchpaul.github.io/kickstart.sh | bash
set -euo pipefail

readonly dotfiles_remote="git@github.com:AnudeepChPaul/terminal-setup.git"
readonly dotfiles_git_dir="$HOME/.cfg"
readonly mise_key_fingerprint="24853EC9F655CE80B48E6C3A8B81C9D17413A06D"
readonly mise_bin="$HOME/.local/bin/mise"

platform=""
gh_freshly_authenticated=0

log() { printf '\033[36m▸\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

detect_platform() {
  case "$(uname -s)" in
    Darwin)
      [ "$(uname -m)" = "arm64" ] || die "only Apple Silicon Macs are supported"
      platform="macos" ;;
    Linux)
      if command -v apt-get >/dev/null; then platform="apt"
      elif command -v zypper >/dev/null; then platform="zypper"
      elif command -v pacman >/dev/null; then platform="pacman"
      else die "unsupported Linux distro (need apt, zypper or pacman)"; fi ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
  log "platform: $platform"
}

install_prereqs() {
  local missing_commands=()
  local required_command
  for required_command in curl git gpg ssh-keygen; do
    command -v "$required_command" >/dev/null || missing_commands+=("$required_command")
  done
  if [ ${#missing_commands[@]} -eq 0 ]; then
    log "prerequisites already installed"
    return
  fi
  log "installing missing prerequisites: ${missing_commands[*]}"
  local package_names=()
  for required_command in "${missing_commands[@]}"; do
    case "$platform:$required_command" in
      macos:gpg) package_names+=(gnupg) ;;
      macos:curl|macos:ssh-keygen) die "$required_command missing from macOS base system" ;;
      apt:gpg) package_names+=(gnupg) ;;
      apt:ssh-keygen) package_names+=(openssh-client) ;;
      zypper:gpg) package_names+=(gpg2) ;;
      zypper:ssh-keygen) package_names+=(openssh-clients) ;;
      pacman:gpg) package_names+=(gnupg) ;;
      pacman:ssh-keygen) package_names+=(openssh) ;;
      *) package_names+=("$required_command") ;;
    esac
  done
  case "$platform" in
    macos)
      if [ ! -x /opt/homebrew/bin/brew ]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      fi
      eval "$(/opt/homebrew/bin/brew shellenv)"
      brew install "${package_names[@]}" ;;
    apt) sudo apt-get update && sudo apt-get install -y "${package_names[@]}" ;;
    zypper) sudo zypper --non-interactive install "${package_names[@]}" ;;
    pacman) sudo pacman -Sy --needed --noconfirm "${package_names[@]}" ;;
  esac
}

install_mise_verified() {
  if [ -x "$mise_bin" ]; then
    log "mise already installed: $("$mise_bin" --version)"
    return
  fi
  log "installing mise (gpg verified)"
  local work_dir
  work_dir="$(mktemp -d)"
  export GNUPGHOME="$work_dir/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$mise_key_fingerprint"
  curl -fsSL -o "$work_dir/install.sh.sig" https://mise.jdx.dev/install.sh.sig
  local gpg_status
  gpg_status="$(gpg --batch --status-fd 1 --output "$work_dir/install.sh" --decrypt "$work_dir/install.sh.sig" 2>/dev/null)" \
    || die "mise installer signature verification failed"
  grep -q "^\[GNUPG:\] VALIDSIG $mise_key_fingerprint " <<<"$gpg_status" \
    || die "mise installer not signed by $mise_key_fingerprint"
  unset GNUPGHOME
  sh "$work_dir/install.sh"
  rm -rf "$work_dir"
}

gh() { "$mise_bin" x gh@latest -- gh "$@"; }

install_gh() {
  if "$mise_bin" where gh@latest >/dev/null 2>&1; then
    log "gh already installed via mise"
    return
  fi
  log "installing gh via mise"
  "$mise_bin" install gh@latest
}

ensure_gh_scopes() {
  local granted_scopes missing_scopes=() required_scope
  granted_scopes="$(gh auth status --hostname github.com 2>&1 | grep -i 'token scopes' || true)"
  for required_scope in admin:public_key admin:ssh_signing_key; do
    grep -q "'$required_scope'" <<<"$granted_scopes" || missing_scopes+=("$required_scope")
  done
  if [ ${#missing_scopes[@]} -gt 0 ]; then
    log "requesting missing gh scopes: ${missing_scopes[*]}"
    gh auth refresh --hostname github.com --scopes "$(IFS=,; echo "${missing_scopes[*]}")" </dev/tty
  fi
}

github_has_key() {
  local key_body="$1" key_type="$2"
  gh ssh-key list 2>/dev/null | awk -v body="$key_body" -v type="$key_type" 'index($0, body) && $NF == type {found=1} END {exit !found}'
}

setup_git_auth() {
  local ssh_key="$HOME/.ssh/id_ed25519"
  if [ ! -f "$ssh_key" ]; then
    log "generating ssh key"
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "$(whoami)@$(hostname -s)" -f "$ssh_key" -N ""
  fi
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    log "authenticating with GitHub"
    gh auth login --hostname github.com --git-protocol ssh --web \
      --scopes admin:public_key,admin:ssh_signing_key,gist </dev/tty
    gh_freshly_authenticated=1
    ensure_gh_scopes
    local public_key_body
    public_key_body="$(awk '{print $2}' "$ssh_key.pub")"
    if ! github_has_key "$public_key_body" authentication; then
      log "uploading ssh authentication key to GitHub"
      gh ssh-key add "$ssh_key.pub" --type authentication --title "$(hostname -s)"
    fi
  else
    log "gh already authenticated, skipping GitHub key setup"
  fi
  ssh-keygen -F github.com >/dev/null 2>&1 || ssh-keyscan github.com >>"$HOME/.ssh/known_hosts" 2>/dev/null
}

setup_signing() {
  local ssh_public_key="$HOME/.ssh/id_ed25519.pub"
  if [ "$gh_freshly_authenticated" -eq 1 ]; then
    local public_key_body
    public_key_body="$(awk '{print $2}' "$ssh_public_key")"
    if ! github_has_key "$public_key_body" signing; then
      log "registering ssh signing key on GitHub"
      gh ssh-key add "$ssh_public_key" --type signing --title "$(hostname -s) signing"
    fi
  fi
  local local_git_config="$HOME/.config/git/config.local"
  if [ ! -f "$local_git_config" ]; then
    local git_name git_email
    read -r -p "git user.name: " git_name </dev/tty
    read -r -p "git user.email: " git_email </dev/tty
    mkdir -p "$(dirname "$local_git_config")"
    git config --file "$local_git_config" user.name "$git_name"
    git config --file "$local_git_config" user.email "$git_email"
    git config --file "$local_git_config" user.signingkey "$ssh_public_key"
  fi
}

dotfiles_git() { git --git-dir="$dotfiles_git_dir" --work-tree="$HOME" "$@"; }

clone_dotfiles() {
  if [ -d "$dotfiles_git_dir" ]; then
    log "dotfiles already cloned at $dotfiles_git_dir"
    return
  fi
  log "cloning dotfiles into $dotfiles_git_dir"
  git clone --bare "$dotfiles_remote" "$dotfiles_git_dir"
  dotfiles_git config status.showUntrackedFiles no
  if ! dotfiles_git checkout 2>/dev/null; then
    local backup_dir
    backup_dir="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
    log "backing up conflicting files to $backup_dir"
    dotfiles_git ls-tree -r --name-only HEAD | while read -r tracked_path; do
      if [ -e "$HOME/$tracked_path" ]; then
        mkdir -p "$backup_dir/$(dirname "$tracked_path")"
        mv "$HOME/$tracked_path" "$backup_dir/$tracked_path"
      fi
    done
    dotfiles_git checkout
  fi
}

run_bootstrap() {
  log "running mise bootstrap"
  cd "$HOME"
  "$mise_bin" trust "$HOME/mise.bootstrap.toml"
  GITHUB_TOKEN="$(gh auth token --hostname github.com)"
  export GITHUB_TOKEN
  MISE_ENV=bootstrap "$mise_bin" bootstrap --yes
}

main() {
  detect_platform
  install_prereqs
  install_mise_verified
  install_gh
  setup_git_auth
  setup_signing
  clone_dotfiles
  run_bootstrap
  printf '\033[32m✓\033[0m done, open a new shell\n'
}

main "$@"
