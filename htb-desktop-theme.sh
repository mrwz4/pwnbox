#!/usr/bin/env bash
#
# htb-desktop-theme.sh — Drag the XFCE box out of 1996.
#
#   - Dark GTK + window-manager theme (Arc-Dark by default; Materia & Dracula
#     also installed so you can switch)
#   - Papirus-Dark icon theme
#   - A handful of Nerd Fonts (JetBrainsMono, FiraCode, Hack, Meslo, Cascadia)
#     so you can try each and keep the one you like
#   - xfce4-terminal styled dark with a Dracula palette
#   - `setfont` and `settheme` helpers to switch live, no clicking around
#
# RUN AS YOUR NORMAL USER, from a terminal INSIDE the RDP/XFCE session
# (not root, not over plain SSH) — live settings need your session bus.
#   ./htb-desktop-theme.sh
#
set -euo pipefail

c()   { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '    \033[1;33m!\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] && { echo "Run as your normal user, not root." >&2; exit 1; }

HAVE_SESSION=1
if [[ -z "${DISPLAY:-}" || -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  HAVE_SESSION=0
  warn "No desktop session detected. Fonts/themes/terminal config will still be"
  warn "installed, but live theme application is skipped — run this from a"
  warn "terminal inside the RDP session, or just log out/in afterwards."
fi

FONT_DIR="$HOME/.local/share/fonts"
THEMES_DIR="$HOME/.themes"
BIN_DIR="$HOME/.local/bin"
TERMRC="$HOME/.config/xfce4/terminal/terminalrc"
mkdir -p "$FONT_DIR" "$THEMES_DIR" "$BIN_DIR" "$(dirname "$TERMRC")"

# ---------------------------------------------------------------------------
# 1. Themes + icons + font tooling from apt (tolerant install).
# ---------------------------------------------------------------------------
c "Installing themes, icons and tooling"
export DEBIAN_FRONTEND=noninteractive
APT_PKGS=(arc-theme materia-gtk-theme papirus-icon-theme gnome-themes-extra
          fonts-firacode xz-utils unzip curl)
AVAIL=()
for p in "${APT_PKGS[@]}"; do apt-cache show "$p" >/dev/null 2>&1 && AVAIL+=("$p"); done
sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y "${AVAIL[@]}" && ok "installed: ${AVAIL[*]}"

# ---------------------------------------------------------------------------
# 2. Nerd Fonts — latest release, one tarball each. Skips already-installed.
#    Cascadia's PATCHED family name is "CaskaydiaCove Nerd Font".
# ---------------------------------------------------------------------------
c "Installing Nerd Fonts"
NERD_BASE="https://github.com/ryanoasis/nerd-fonts/releases/latest/download"
NERD_FONTS=(JetBrainsMono FiraCode Hack Meslo CascadiaCode)
for f in "${NERD_FONTS[@]}"; do
  dest="$FONT_DIR/$f"
  if [[ -d "$dest" && -n "$(ls -A "$dest" 2>/dev/null)" ]]; then ok "$f already present"; continue; fi
  tmp="$(mktemp -d)"
  if curl -fsSL "$NERD_BASE/$f.tar.xz" -o "$tmp/$f.tar.xz"; then
    mkdir -p "$dest"
    tar -xf "$tmp/$f.tar.xz" -C "$dest" --wildcards '*.ttf' '*.otf' 2>/dev/null \
      || tar -xf "$tmp/$f.tar.xz" -C "$dest"
    ok "$f"
  else warn "$f download failed, skipping"; fi
  rm -rf "$tmp"
done
fc-cache -f "$FONT_DIR" >/dev/null 2>&1 && ok "font cache rebuilt"

# ---------------------------------------------------------------------------
# 3. Dracula GTK theme (cool factor). Arc-Dark/Materia already came via apt.
# ---------------------------------------------------------------------------
c "Fetching Dracula GTK theme"
if [[ -d "$THEMES_DIR/Dracula" ]]; then ok "already present"
elif git clone --depth=1 -q https://github.com/dracula/gtk.git "$THEMES_DIR/Dracula" 2>/dev/null; then
  ok "installed"
else warn "Dracula clone failed (Arc-Dark & Materia-Dark still available)"; fi

# ---------------------------------------------------------------------------
# 4. Style the terminal: dark, Dracula palette, JetBrainsMono Nerd Font.
# ---------------------------------------------------------------------------
c "Styling xfce4-terminal"
[[ -f "$TERMRC" ]] || printf '[Configuration]\n' > "$TERMRC"
grep -q '^\[Configuration\]' "$TERMRC" || sed -i '1i [Configuration]' "$TERMRC"
set_key() {  # set_key <Key> <Value> — set or replace under [Configuration]
  local k="$1" v="$2"
  if grep -q "^$k=" "$TERMRC"; then
    sed -i "s|^$k=.*|$k=$v|" "$TERMRC"
  else
    sed -i "/^\[Configuration\]/a $k=$v" "$TERMRC"
  fi
}
set_key FontName          "JetBrainsMono Nerd Font 12"
set_key FontUseSystem     "FALSE"
set_key ColorForeground   "#f8f8f2"
set_key ColorBackground   "#282a36"
set_key ColorCursor       "#f8f8f2"
set_key ColorPalette      "#21222c;#ff5555;#50fa7b;#f1fa8c;#bd93f9;#ff79c6;#8be9fd;#f8f8f2;#6272a4;#ff6e6e;#69ff94;#ffffa5;#d6acff;#ff92df;#a4ffff;#ffffff"
set_key ScrollingLines    "100000"
set_key MiscShowUnsafePasteDialog "FALSE"
ok "terminal styled"

# ---------------------------------------------------------------------------
# 5. Apply the dark theme live (if we're in a session).
# ---------------------------------------------------------------------------
xq() { xfconf-query "$@" 2>/dev/null || warn "xfconf: ${*: -1} not applied"; }
if [[ $HAVE_SESSION -eq 1 ]]; then
  c "Applying Arc-Dark + Papirus-Dark"
  xq -c xsettings -p /Net/ThemeName        -s "Arc-Dark"
  xq -c xfwm4     -p /general/theme         -s "Arc-Dark"
  xq -c xsettings -p /Net/IconThemeName     -s "Papirus-Dark"
  xq -c xsettings -p /Gtk/MonospaceFontName -s "JetBrainsMono Nerd Font 11"
  ok "applied"
fi

# ---------------------------------------------------------------------------
# 6. Live switcher helpers -> ~/.local/bin  (PATH already set by htb-setup).
# ---------------------------------------------------------------------------
c "Installing setfont / settheme helpers"

cat > "$BIN_DIR/setfont" <<'SETFONT_EOF'
#!/usr/bin/env bash
# setfont [number|family] [size]  — switch XFCE mono + terminal font live.
set -euo pipefail
TERMRC="$HOME/.config/xfce4/terminal/terminalrc"
mapfile -t FAMS < <(fc-list : family 2>/dev/null | tr ',' '\n' \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -i 'Nerd Font' | sort -u)
[[ ${#FAMS[@]} -eq 0 ]] && { echo "No Nerd Fonts installed."; exit 1; }
sel="${1:-}"; size="${2:-12}"
if [[ -z "$sel" ]]; then
  echo "Installed Nerd Font families:"
  i=1; for f in "${FAMS[@]}"; do printf "  %2d) %s\n" "$i" "$f"; i=$((i+1)); done
  echo "Usage: setfont <number|name> [size]"; exit 0
fi
if [[ "$sel" =~ ^[0-9]+$ ]]; then fam="${FAMS[$((sel-1))]:-}"; else fam="$sel"; fi
[[ -z "$fam" ]] && { echo "invalid selection"; exit 1; }
xfconf-query -c xsettings -p /Gtk/MonospaceFontName -s "$fam $size" 2>/dev/null || true
[[ -f "$TERMRC" ]] || printf '[Configuration]\n' > "$TERMRC"
grep -q '^\[Configuration\]' "$TERMRC" || sed -i '1i [Configuration]' "$TERMRC"
if grep -q '^FontName=' "$TERMRC"; then sed -i "s|^FontName=.*|FontName=$fam $size|" "$TERMRC"
else sed -i "/^\[Configuration\]/a FontName=$fam $size" "$TERMRC"; fi
if grep -q '^FontUseSystem=' "$TERMRC"; then sed -i "s|^FontUseSystem=.*|FontUseSystem=FALSE|" "$TERMRC"
else sed -i "/^\[Configuration\]/a FontUseSystem=FALSE" "$TERMRC"; fi
echo "Font -> $fam $size   (open a new terminal window/tab to see it)"
SETFONT_EOF
chmod +x "$BIN_DIR/setfont"

cat > "$BIN_DIR/settheme" <<'SETTHEME_EOF'
#!/usr/bin/env bash
# settheme [number|name]  — switch GTK + window-manager theme live.
set -euo pipefail
mapfile -t THEMES < <(find "$HOME/.themes" /usr/share/themes -maxdepth 2 \
  -type d -name 'gtk-3.0' 2>/dev/null | sed 's#/gtk-3.0##; s#.*/##' | sort -u)
[[ ${#THEMES[@]} -eq 0 ]] && { echo "No themes found."; exit 1; }
sel="${1:-}"
if [[ -z "$sel" ]]; then
  echo "Available GTK themes:"
  i=1; for t in "${THEMES[@]}"; do printf "  %2d) %s\n" "$i" "$t"; i=$((i+1)); done
  echo "Usage: settheme <number|name>"; exit 0
fi
if [[ "$sel" =~ ^[0-9]+$ ]]; then th="${THEMES[$((sel-1))]:-}"; else th="$sel"; fi
[[ -z "$th" ]] && { echo "invalid selection"; exit 1; }
xfconf-query -c xsettings -p /Net/ThemeName -s "$th" 2>/dev/null || true
xfconf-query -c xfwm4     -p /general/theme  -s "$th" 2>/dev/null || true
echo "Theme -> $th"
SETTHEME_EOF
chmod +x "$BIN_DIR/settheme"
ok "helpers installed"

c "Done. Log out/in if the theme didn't apply instantly."
echo "    setfont            # list installed Nerd Fonts"
echo "    setfont 2 13       # switch to font #2 at size 13"
echo "    settheme           # list themes (Arc-Dark, Materia-dark, Dracula, ...)"
echo "    settheme Dracula   # switch theme"
