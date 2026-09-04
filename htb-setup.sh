#!/usr/bin/env bash
#
# htb-setup.sh — Turn a fresh Debian 13 (Trixie) VM into a remote HTB box.
#
#   - xrdp + XFCE for responsive RDP
#   - pentest tooling for *nix/Windows boxes (no wifi/wireless cruft)
#   - SecLists + rockyou wordlists at predictable paths
#   - zsh + Oh My Zsh + autosuggestions/syntax-highlighting
#   - HTB aliases + `mkhtb` box scaffolder (with CLAUDE.md/AGENTS.md notes)
#   - ligolo-ng, netexec, evil-winrm, Claude Code
#
# Idempotent: safe to re-run. Run as root (sudo ./htb-setup.sh).
# Optional: TARGET_USER=youruser sudo -E ./htb-setup.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Context: figure out the unprivileged user we're setting up for.
#    User-level installs (Oh My Zsh, pipx, npm globals) must NOT run as root.
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo "Set TARGET_USER to a non-root user, e.g.  TARGET_USER=tom sudo -E $0" >&2
  exit 1
fi
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
HTB_DIR="$USER_HOME/htb"

c()   { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '    \033[1;33m!\033[0m %s\n' "$*"; }
as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

c "Setting up for user: $TARGET_USER  (home: $USER_HOME)"

# ---------------------------------------------------------------------------
# 1. APT base. Trixie carries most of what we need. Install tolerantly:
#    filter to packages that actually exist so one bad name can't abort apt.
# ---------------------------------------------------------------------------
c "Updating APT + enabling contrib/non-free components"
export DEBIAN_FRONTEND=noninteractive
# Trixie uses deb822 .sources; add components if missing.
if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
  sed -i 's/^Components: .*/Components: main contrib non-free non-free-firmware/' \
    /etc/apt/sources.list.d/debian.sources || true
fi
apt-get update -y

APT_PKGS=(
  # shell / base
  zsh git curl wget build-essential ca-certificates gnupg jq unzip
  ripgrep fzf bat tmux vim
  # desktop + remote
  xfce4 xfce4-terminal xrdp dbus-x11
  # recon / scanning
  nmap masscan netcat-traditional netcat-openbsd socat proxychains4
  dnsutils whois iputils-ping
  # web
  gobuster ffuf dirb nikto whatweb wfuzz sqlmap
  # smb / ad / windows
  smbclient smbmap ldap-utils python3-impacket krb5-user
  # cracking
  hydra john hashcat
  # python
  python3 python3-pip python3-venv pipx
  # ruby (for evil-winrm)
  ruby ruby-dev
)

c "Installing base packages (skipping any not in Trixie)"
AVAIL=(); MISSING=()
for p in "${APT_PKGS[@]}"; do
  if apt-cache show "$p" >/dev/null 2>&1; then AVAIL+=("$p"); else MISSING+=("$p"); fi
done
apt-get install -y --no-install-recommends "${AVAIL[@]}"
ok "Installed ${#AVAIL[@]} packages"
[[ ${#MISSING[@]} -gt 0 ]] && warn "Not in repo, handled elsewhere or skip: ${MISSING[*]}"

# ---------------------------------------------------------------------------
# 2. Python tooling via pipx (isolated venvs, binaries on PATH).
#    netexec/nxc pulled from git for freshness; others from PyPI.
# ---------------------------------------------------------------------------
c "Python tools via pipx"
as_user 'pipx ensurepath >/dev/null 2>&1 || true'
pipx_install() {
  local spec="$1" name="$2"
  if as_user "pipx list --short 2>/dev/null | grep -q '^${name} '"; then
    ok "$name already installed"
  else
    as_user "pipx install '$spec'" && ok "$name" || warn "pipx $name failed"
  fi
}
pipx_install 'git+https://github.com/Pennyw0rth/NetExec' netexec
pipx_install 'bloodhound-ce'                             bloodhound-ce   # bloodhound-python (CE)
pipx_install 'certipy-ad'                                certipy-ad
pipx_install 'coercer'                                   coercer
pipx_install 'pypykatz'                                  pypykatz
pipx_install 'mitm6'                                     mitm6

# ---------------------------------------------------------------------------
# 3. Ruby gem: evil-winrm
# ---------------------------------------------------------------------------
c "evil-winrm (gem)"
if gem list -i evil-winrm >/dev/null 2>&1; then ok "already installed";
else gem install --no-document evil-winrm && ok "installed" || warn "gem failed"; fi

# ---------------------------------------------------------------------------
# 4. GitHub release binaries: ligolo-ng (your tunneler of choice).
#    Grabs latest linux/amd64 proxy + agent, drops in /usr/local/bin.
# ---------------------------------------------------------------------------
c "ligolo-ng (proxy + agent)"
install_ligolo() {
  local api="https://api.github.com/repos/nicocha30/ligolo-ng/releases/latest"
  local tmp; tmp="$(mktemp -d)"
  local urls
  urls="$(curl -fsSL "$api" \
    | jq -r '.assets[].browser_download_url' \
    | grep -Ei 'linux_amd64.*\.tar\.gz$' || true)"
  [[ -z "$urls" ]] && { warn "ligolo release lookup failed"; rm -rf "$tmp"; return; }
  while read -r u; do
    [[ -z "$u" ]] && continue
    curl -fsSL "$u" -o "$tmp/a.tgz" && tar -xzf "$tmp/a.tgz" -C "$tmp"
  done <<< "$urls"
  find "$tmp" -maxdepth 1 -type f -name 'ligolo-ng*' -exec install -m755 {} /usr/local/bin/ \; 2>/dev/null || true
  find "$tmp" -maxdepth 1 -type f -name 'agent*'      -exec install -m755 {} /usr/local/bin/ligolo-agent \; 2>/dev/null || true
  rm -rf "$tmp"
}
if command -v ligolo-ng >/dev/null 2>&1 || ls /usr/local/bin/ligolo-ng* >/dev/null 2>&1; then
  ok "already present"; else install_ligolo && ok "installed"; fi

# ---------------------------------------------------------------------------
# 4b. feroxbuster — NOT in Debian repos (the apt package is Kali's), so pull
#     the release binary. Asset lookup via the API so a renamed zip won't 404.
# ---------------------------------------------------------------------------
c "feroxbuster (release binary)"
install_ferox() {
  local api="https://api.github.com/repos/epi052/feroxbuster/releases/latest"
  local url tmp; tmp="$(mktemp -d)"
  url="$(curl -fsSL "$api" \
    | jq -r '.assets[].browser_download_url' \
    | grep -Ei 'x86_64-linux-feroxbuster\.zip$' | head -n1 || true)"
  [[ -z "$url" ]] && { warn "feroxbuster release lookup failed"; rm -rf "$tmp"; return 1; }
  if curl -fsSL "$url" -o "$tmp/ferox.zip" && unzip -oq "$tmp/ferox.zip" -d "$tmp"; then
    install -m755 "$tmp/feroxbuster" /usr/local/bin/ && rm -rf "$tmp" && return 0
  fi
  rm -rf "$tmp"; return 1
}
if command -v feroxbuster >/dev/null 2>&1; then ok "already present"
else install_ferox && ok "installed" || warn "feroxbuster failed (install manually later)"; fi

# ---------------------------------------------------------------------------
# 5. Node + Claude Code (you run this per-box on HTB).
# ---------------------------------------------------------------------------
c "Node.js + Claude Code"
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1 || \
    apt-get install -y nodejs npm
  apt-get install -y nodejs >/dev/null 2>&1 || true
fi
if as_user 'command -v claude >/dev/null 2>&1'; then ok "claude already installed";
else
  # Prefer a user-level npm prefix so no global sudo installs.
  as_user 'mkdir -p "$HOME/.npm-global" && npm config set prefix "$HOME/.npm-global"' || true
  as_user 'npm install -g @anthropic-ai/claude-code' && ok "Claude Code installed" \
    || warn "Claude Code install failed (install manually later)"
fi

# ---------------------------------------------------------------------------
# 6. Wordlists. SecLists/`wordlists` are Kali packages, NOT in Debian, so fetch
#    SecLists from GitHub (~1.8 GB) and lift rockyou out of it. SecLists is big,
#    so pick a location with space: WORDLISTS_DIR if set, else /usr/share if it
#    has room, else the roomiest real mount — then symlink the canonical paths.
#    Override with:  WORDLISTS_DIR=/data sudo -E ./htb-setup.sh
# ---------------------------------------------------------------------------
c "Wordlists (SecLists + rockyou)"
mkdir -p /usr/share/wordlists
REQUIRED_MB=2500                                  # ~1.8 GB extracted + download slack
avail_mb() { df -Pk "$1" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}'; }

# Decide where the bulk actually lands.
if [[ -n "${WORDLISTS_DIR:-}" ]]; then
  SL_DIR="${WORDLISTS_DIR%/}/seclists"
elif [[ "$(avail_mb /usr/share)" -ge "$REQUIRED_MB" ]]; then
  SL_DIR="/usr/share/seclists"
else
  best="$(df -Pk | awk 'NR>1 && $1!~/^(tmpfs|udev|devtmpfs|overlay)$/ {print $4, $6}' \
          | sort -rn | awk 'NR==1{print $2}')"
  [[ -z "$best" ]] && best="$USER_HOME"
  SL_DIR="${best%/}/wordlists/seclists"
  warn "root has <${REQUIRED_MB}MB free — placing SecLists on $best"
fi
SL_PARENT="$(dirname "$SL_DIR")"

# Fetch (tarball, no .git overhead) only if not already there and space allows.
if [[ -d "$SL_DIR" && -n "$(ls -A "$SL_DIR" 2>/dev/null)" ]]; then
  ok "SecLists already present at $SL_DIR"
else
  mkdir -p "$SL_PARENT"
  if [[ "$(avail_mb "$SL_PARENT")" -lt "$REQUIRED_MB" ]]; then
    warn "only $(avail_mb "$SL_PARENT")MB free at $SL_PARENT (<${REQUIRED_MB}) — skipping SecLists"
    warn "free some space or re-run with WORDLISTS_DIR=/path/with/room"
  else
    warn "downloading SecLists (~1.8 GB) to $SL_DIR"
    if curl -fL https://github.com/danielmiessler/SecLists/archive/refs/heads/master.tar.gz \
         | tar xz -C "$SL_PARENT" 2>/dev/null && [[ -d "$SL_PARENT/SecLists-master" ]]; then
      rm -rf "$SL_DIR"; mv "$SL_PARENT/SecLists-master" "$SL_DIR"; ok "SecLists installed"
    else
      warn "SecLists download/extract failed"; rm -rf "$SL_PARENT/SecLists-master"
    fi
  fi
fi

# Canonical symlinks (just bytes — safe even on a full-ish root).
if [[ -d "$SL_DIR" ]]; then
  [[ "$SL_DIR" != "/usr/share/seclists" ]] && ln -sfn "$SL_DIR" /usr/share/seclists
  ln -sfn "$SL_DIR" /usr/share/wordlists/seclists
  ok "seclists -> $SL_DIR"
fi

# rockyou.txt — extract beside SecLists (same roomy mount), link to expected path.
RY_SRC="$SL_DIR/Passwords/Leaked-Databases/rockyou.txt.tar.gz"
if [[ -e /usr/share/wordlists/rockyou.txt ]]; then ok "rockyou already present"
elif [[ -f "$RY_SRC" ]]; then
  tar -xf "$RY_SRC" -C "$SL_PARENT" \
    && ln -sfn "$SL_PARENT/rockyou.txt" /usr/share/wordlists/rockyou.txt \
    && ok "rockyou.txt -> $SL_PARENT/rockyou.txt"
else warn "rockyou source not found (SecLists incomplete?)"; fi

# ---------------------------------------------------------------------------
# 7. xrdp + XFCE. GNOME breaks xrdp; XFCE is light and responsive over RDP.
# ---------------------------------------------------------------------------
c "Configuring xrdp -> XFCE session"
echo "startxfce4" > "$USER_HOME/.xsession"
chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.xsession"
# Make xrdp default to XFCE for the whole box too.
cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
if [ -r /etc/default/locale ]; then . /etc/default/locale; export LANG LANGUAGE; fi
startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh
adduser xrdp ssl-cert >/dev/null 2>&1 || true
systemctl enable --now xrdp >/dev/null 2>&1 && ok "xrdp enabled on :3389"

# ---------------------------------------------------------------------------
# 8. zsh + Oh My Zsh + plugins (autofill = zsh-autosuggestions).
# ---------------------------------------------------------------------------
c "Oh My Zsh + plugins"
OMZ="$USER_HOME/.oh-my-zsh"
if [[ ! -d "$OMZ" ]]; then
  as_user 'RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"' \
    && ok "Oh My Zsh installed"
else ok "Oh My Zsh already present"; fi

ZCUST="$OMZ/custom"
as_user "[[ -d '$ZCUST/plugins/zsh-autosuggestions' ]] || git clone -q https://github.com/zsh-users/zsh-autosuggestions '$ZCUST/plugins/zsh-autosuggestions'"
as_user "[[ -d '$ZCUST/plugins/zsh-syntax-highlighting' ]] || git clone -q https://github.com/zsh-users/zsh-syntax-highlighting '$ZCUST/plugins/zsh-syntax-highlighting'"
ok "plugins present"

# Enable plugins in .zshrc (replace the default plugins line once).
ZRC="$USER_HOME/.zshrc"
if grep -q '^plugins=(git)$' "$ZRC" 2>/dev/null; then
  sed -i 's/^plugins=(git)$/plugins=(git fzf zsh-autosuggestions zsh-syntax-highlighting)/' "$ZRC"
fi

# ---------------------------------------------------------------------------
# 9. HTB config block: aliases + mkhtb. Idempotent via marker fences.
# ---------------------------------------------------------------------------
c "Writing HTB aliases + mkhtb into .zshrc"
MARK_BEGIN="# >>> htb-setup >>>"
MARK_END="# <<< htb-setup <<<"
# Strip any previous block, then re-append the current one.
if grep -qF "$MARK_BEGIN" "$ZRC" 2>/dev/null; then
  sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$ZRC"
fi

cat >> "$ZRC" <<EOF
$MARK_BEGIN
export HTB_DIR="\$HOME/htb"
export PATH="\$HOME/.local/bin:\$HOME/.npm-global/bin:\$PATH"

# --- quick nav / helpers ---
alias htb='cd "\$HTB_DIR"'
alias serve='python3 -m http.server 8000'          # file transfer to victim
alias tun='ip -4 -o addr show tun0 2>/dev/null | awk "{print \\\$4}" | cut -d/ -f1'
alias vpnup='sudo openvpn --daemon --config "\$HTB_DIR"/*.ovpn && echo "VPN up"; sleep 3; tun'
alias vpndown='sudo pkill -f openvpn && echo "VPN down"'
alias ll='ls -lah'

# Show/set the current target IP (persists in \$HTB_DIR/.target).
target()   { [[ -f "\$HTB_DIR/.target" ]] && cat "\$HTB_DIR/.target" || echo "no target set"; }
settarget(){ echo "\$1" > "\$HTB_DIR/.target"; export IP="\$1"; echo "IP=\$1"; }

# mkhtb <name> [ip] : scaffold a box folder, drop notes, set target, cd in.
mkhtb() {
  local name="\$1" ip="\$2"
  if [[ -z "\$name" ]]; then echo "usage: mkhtb <name> [ip]"; return 1; fi
  local dir="\$HTB_DIR/\$name"
  mkdir -p "\$dir"/{nmap,loot,exploits,www,scans,creds}

  # Per-box notes matching your Claude Code workflow.
  if [[ ! -f "\$dir/CLAUDE.md" ]]; then
    cat > "\$dir/CLAUDE.md" <<NOTE
# \$name — HTB working notes

- **Box:** \$name
- **IP:** \${ip:-TBD}
- **tun0:** \$(ip -4 -o addr show tun0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1)
- **Started:** \$(date +%F)

## Recon
- [ ] full TCP nmap (nmap/ dir)
- [ ] service/version enum
- [ ] web content discovery (feroxbuster/ffuf)

## Foothold

## PrivEsc

## Loot / creds
- (creds/, loot/)

## Tunneling
- ligolo-ng: \\\`ligolo-ng -selfcert\\\` on attacker, agent on target -> \\\`interface_create\\\`
NOTE
    ln -sf CLAUDE.md "\$dir/AGENTS.md"
  fi

  # Set target + convenient hosts entry.
  if [[ -n "\$ip" ]]; then
    echo "\$ip" > "\$HTB_DIR/.target"; export IP="\$ip"
    if ! grep -q "\\s\$name.htb\$" /etc/hosts 2>/dev/null; then
      echo "\$ip \$name.htb" | sudo tee -a /etc/hosts >/dev/null
    fi
    echo "IP=\$ip  (\$name.htb added to /etc/hosts)"
  fi
  cd "\$dir"
  echo "-> \$dir"
}

# nmapa <ip> : baseline all-ports + service scan into ./nmap/
nmapa() {
  local ip="\${1:-\$IP}"
  [[ -z "\$ip" ]] && { echo "usage: nmapa <ip>  (or set IP)"; return 1; }
  mkdir -p nmap
  nmap -p- --min-rate 5000 -T4 -oN nmap/allports.txt "\$ip"
  local ports; ports=\$(grep -oP '^\d+(?=/tcp\s+open)' nmap/allports.txt | paste -sd,)
  [[ -n "\$ports" ]] && nmap -p"\$ports" -sCV -oN nmap/services.txt "\$ip"
}

# --- ligolo-ng ---
# Two workflows: (a) let the proxy console make the interface via
# 'interface_create --name ligolo', or (b) pre-make the tun here with
# ligolo-tun and just add routes. ligolo-route works either way.
alias ligolo-start='sudo ligolo-ng -selfcert'            # start proxy (self-signed cert)
ligolo-tun()   { sudo ip tuntap add user "\$USER" mode tun ligolo 2>/dev/null; sudo ip link set ligolo up && echo "ligolo tun up"; }
ligolo-route() { [[ -z "\$1" ]] && { echo "usage: ligolo-route <cidr>"; return 1; }; sudo ip route add "\$1" dev ligolo && echo "routed \$1 -> ligolo"; }
ligolo-clean() { sudo ip link set ligolo down 2>/dev/null; sudo ip tuntap del mode tun ligolo 2>/dev/null; echo "ligolo tun removed"; }
$MARK_END
EOF
ok "HTB block written"

# ---------------------------------------------------------------------------
# 9b. tmux.conf — HTB-friendly. Backs up any existing config once.
# ---------------------------------------------------------------------------
c "Writing ~/.tmux.conf"
TMUXCONF="$USER_HOME/.tmux.conf"
if [[ -f "$TMUXCONF" && ! -f "$TMUXCONF.pre-htb.bak" ]] && ! grep -q 'HTB-friendly' "$TMUXCONF"; then
  cp "$TMUXCONF" "$TMUXCONF.pre-htb.bak"; warn "backed up existing config -> .tmux.conf.pre-htb.bak"
fi
cat > "$TMUXCONF" <<'EOF'
# ~/.tmux.conf — HTB-friendly
set -g mouse on
set -g history-limit 50000
setw -g mode-keys vi
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# Splits keep the current path (so new panes open in the box folder).
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

bind r source-file ~/.tmux.conf \; display "reloaded"

# Toggle logging the active pane to <boxpath>/tmux-<window>.log — handy per box.
bind P pipe-pane -o "cat >> #{pane_current_path}/tmux-#W.log" \; display "logging toggled"

# Alt+arrows to move between panes without the prefix.
bind -n M-Left  select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up    select-pane -U
bind -n M-Down  select-pane -D

set -g status-style bg=black,fg=green
set -g status-right '#[fg=cyan]%H:%M #[fg=yellow]#h'
EOF
chown "$TARGET_USER:$TARGET_USER" "$TMUXCONF"
ok "tmux configured"

# ---------------------------------------------------------------------------
# 10. Make zsh the default shell.
# ---------------------------------------------------------------------------
c "Setting zsh as default shell for $TARGET_USER"
chsh -s "$(command -v zsh)" "$TARGET_USER" && ok "done"

chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.zshrc" "$OMZ" 2>/dev/null || true

c "All done. Reboot (or restart xrdp), RDP into :3389, log in as $TARGET_USER."
echo "    Try:  mkhtb garfield 10.129.22.188"
echo "    Undo: sudo -E ./htb-teardown.sh   (config only; --tools --xrdp --all for more)"
