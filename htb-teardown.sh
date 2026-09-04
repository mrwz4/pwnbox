#!/usr/bin/env bash
#
# htb-teardown.sh — Undo htb-setup.sh.
#
# Default (no flags): config only — removes the .zshrc HTB block, restores
#   tmux.conf, strips *.htb /etc/hosts entries, reverts shell to bash.
#   Leaves apt packages, pipx tools, ligolo, xrdp in place.
#
# Flags (combine freely):
#   --tools   uninstall pipx tools, evil-winrm gem, Claude Code, ligolo bins
#   --xrdp    disable + purge xrdp and XFCE
#   --htbdir  also delete ~/htb (your box folders + loot!) — asks first
#   --all     --tools --xrdp (does NOT imply --htbdir)
#
# Run as root:  TARGET_USER=tom sudo -E ./htb-teardown.sh [flags]
#
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0" >&2; exit 1; }
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
[[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]] && \
  { echo "Set TARGET_USER to a non-root user." >&2; exit 1; }
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

DO_TOOLS=0; DO_XRDP=0; DO_HTBDIR=0
for a in "$@"; do case "$a" in
  --tools) DO_TOOLS=1;;
  --xrdp)  DO_XRDP=1;;
  --htbdir) DO_HTBDIR=1;;
  --all)   DO_TOOLS=1; DO_XRDP=1;;
  *) echo "unknown flag: $a" >&2; exit 1;;
esac; done

c()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok() { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }

# --- 1. .zshrc HTB block ---------------------------------------------------
c "Removing HTB block from .zshrc"
ZRC="$USER_HOME/.zshrc"
if [[ -f "$ZRC" ]] && grep -qF "# >>> htb-setup >>>" "$ZRC"; then
  sed -i "/# >>> htb-setup >>>/,/# <<< htb-setup <<</d" "$ZRC"
  ok "block removed"
else ok "no block present"; fi

# --- 2. tmux.conf ----------------------------------------------------------
c "Restoring tmux.conf"
TMUXCONF="$USER_HOME/.tmux.conf"
if [[ -f "$TMUXCONF.pre-htb.bak" ]]; then
  mv "$TMUXCONF.pre-htb.bak" "$TMUXCONF"; ok "restored prior config"
elif [[ -f "$TMUXCONF" ]] && grep -q 'HTB-friendly' "$TMUXCONF"; then
  rm -f "$TMUXCONF"; ok "removed our config"
else ok "nothing to restore"; fi

# --- 3. /etc/hosts ---------------------------------------------------------
c "Stripping *.htb entries from /etc/hosts"
if grep -qE '\s\S+\.htb$' /etc/hosts; then
  sed -i.bak -E '/\s\S+\.htb$/d' /etc/hosts; ok "removed (backup: /etc/hosts.bak)"
else ok "none found"; fi

# --- 4. default shell ------------------------------------------------------
c "Reverting default shell to bash"
chsh -s /bin/bash "$TARGET_USER" && ok "done"

# --- 5. tools (opt-in) -----------------------------------------------------
if [[ $DO_TOOLS -eq 1 ]]; then
  c "Removing pipx tools / gem / Claude Code / ligolo"
  for t in netexec bloodhound-ce certipy-ad coercer pypykatz mitm6; do
    as_user "pipx uninstall $t >/dev/null 2>&1" && ok "pipx $t" || true
  done
  gem uninstall -aIx evil-winrm >/dev/null 2>&1 && ok "evil-winrm" || true
  as_user 'npm uninstall -g @anthropic-ai/claude-code >/dev/null 2>&1' && ok "claude-code" || true
  rm -f /usr/local/bin/ligolo-ng* /usr/local/bin/ligolo-agent && ok "ligolo bins" || true
  apt-get purge -y metasploit-framework >/dev/null 2>&1 && ok "metasploit" || true
  rm -f /etc/apt/sources.list.d/metasploit-framework.list /usr/share/keyrings/metasploit-framework.gpg
  rm -rf /opt/metasploit-framework
fi

# --- 6. xrdp/xfce (opt-in) -------------------------------------------------
if [[ $DO_XRDP -eq 1 ]]; then
  c "Disabling + purging xrdp and XFCE"
  systemctl disable --now xrdp >/dev/null 2>&1 || true
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y 'xrdp' 'xfce4*' >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true
  rm -f "$USER_HOME/.xsession"
  ok "removed"
fi

# --- 7. ~/htb (opt-in, destructive) ---------------------------------------
if [[ $DO_HTBDIR -eq 1 ]]; then
  c "Deleting ~/htb"
  if [[ -d "$USER_HOME/htb" ]]; then
    read -rp "    Delete $USER_HOME/htb and all box data? [y/N] " ans
    [[ "$ans" == [yY] ]] && rm -rf "$USER_HOME/htb" && ok "deleted" || ok "kept"
  else ok "not present"; fi
fi

c "Teardown complete."
