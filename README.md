# HTB Debian 13 box setup

Turns a fresh Debian 13 (Trixie) VM into a remote-accessible Hack The Box
workstation: RDP over XFCE, a focused pentest toolset for *nix/Windows boxes,
wordlists at predictable paths, and a zsh environment with HTB helpers.

No wireless/wifi-cracking tooling — this is aimed at remote HTB play, not
physical/RF work.

## Contents

| File | Purpose |
|------|---------|
| `htb-setup.sh` | Provisions the box. Idempotent — safe to re-run. |
| `htb-teardown.sh` | Reverses the setup. Config-only by default; flags for more. |

## Requirements

- A fresh Debian 13 (Trixie) install with a non-root user that has sudo.
- Internet access (GitHub, PyPI, npm, apt).
- Run as root via sudo. Preserve your environment with `-E` so `TARGET_USER`
  and `SUDO_USER` resolve correctly.

## Setup

```sh
chmod +x htb-setup.sh
sudo -E ./htb-setup.sh
# or target a specific user:
TARGET_USER=tom sudo -E ./htb-setup.sh
```

After it finishes, reboot (or `systemctl restart xrdp`), then RDP to the VM on
port 3389 and log in as your user. The XFCE session starts automatically.

### What gets installed

- **Remote desktop:** xrdp bound to an XFCE session (GNOME is avoided — it does
  not play well with xrdp).
- **Recon / scanning:** nmap, masscan, netcat, socat, proxychains4, dnsutils.
- **Web:** ffuf, gobuster, dirb, nikto, whatweb, wfuzz, sqlmap.
- **SMB / AD / Windows:** smbclient, smbmap, impacket, ldap-utils, krb5, plus
  netexec (nxc), certipy, bloodhound-ce, coercer, pypykatz, mitm6, evil-winrm.
- **Cracking:** hydra, john, hashcat.
- **Release binaries** (not in Debian repos, pulled from GitHub into
  `/usr/local/bin`): ligolo-ng (proxy + agent) and feroxbuster.
- **Wordlists:** SecLists cloned from GitHub to `/usr/share/seclists` (~1.8 GB,
  symlinked at `/usr/share/wordlists/seclists`), with rockyou extracted from it
  to `/usr/share/wordlists/rockyou.txt`. Note: Debian has no `seclists` or
  `wordlists` package — those are Kali-only — so this is a git clone, not apt.
- **Shell:** zsh + Oh My Zsh with `zsh-autosuggestions` (autofill) and
  `zsh-syntax-highlighting`.
- **Notes:** Claude Code (`claude`) for the per-box CLAUDE.md workflow.

Python tools are installed with pipx (each in its own venv, binary on PATH), so
impacket's dependency tree cannot break the system interpreter.

## Daily workflow

### Box scaffolding

```sh
mkhtb garfield 10.129.22.188
```

Creates `~/htb/garfield/` with `nmap loot exploits www scans creds`
subdirectories, writes a `CLAUDE.md` (symlinked to `AGENTS.md`) pre-filled with
the box name, IP, current tun0 address and date, sets `$IP`, adds
`garfield.htb` to `/etc/hosts`, and drops you into the folder. The IP argument
is optional — omit it to just scaffold.

### Aliases and functions

| Command | Does |
|---------|------|
| `htb` | cd to `~/htb` |
| `mkhtb <name> [ip]` | Scaffold a box folder, set target, cd in |
| `target` / `settarget <ip>` | Show / set the current target (persisted) |
| `tun` | Print the tun0 IP |
| `nmapa [ip]` | All-ports scan, then a service scan on what's open, into `nmap/` |
| `serve` | `python3 -m http.server 8000` for file transfer |
| `vpnup` / `vpndown` | Start/stop OpenVPN from a `.ovpn` in `~/htb/` |
| `ligolo-start` | Start the ligolo-ng proxy with a self-signed cert |
| `ligolo-tun` | Create and bring up the `ligolo` tun interface |
| `ligolo-route <cidr>` | Route a target network through `ligolo` |
| `ligolo-clean` | Tear the `ligolo` interface down |

`interface_create` and session start are commands inside the ligolo-ng proxy
console, not shell commands, so they are not aliased. Either let the console
create the interface, or pre-make it with `ligolo-tun`; `ligolo-route` works
with both.

### VPN

Drop your Hack The Box `.ovpn` file in `~/htb/`, then `vpnup`. Confirm with
`tun`.

### tmux

`~/.tmux.conf` is configured for remote use: mouse on, 50k scrollback, vi copy
mode, 1-indexed panes, `|` and `-` splits that keep the current path, and
Alt+arrows to move between panes.

| Binding | Does |
|---------|------|
| `prefix + \|` / `prefix + -` | Split horizontally / vertically |
| `prefix + P` | Toggle logging the active pane to `<boxpath>/tmux-<window>.log` |
| `prefix + r` | Reload the config |

Default prefix is unchanged (`Ctrl-b`).

## Teardown

Config-only by default — leaves packages and tools in place:

```sh
sudo -E ./htb-teardown.sh
```

This removes the `.zshrc` HTB block, restores `~/.tmux.conf` (from the
`.pre-htb.bak` backup if one exists), strips `*.htb` entries from `/etc/hosts`,
and reverts the login shell to bash.

Flags, combinable:

| Flag | Also does |
|------|-----------|
| `--tools` | Uninstall pipx tools, evil-winrm, Claude Code, ligolo binaries |
| `--xrdp` | Disable and purge xrdp and XFCE |
| `--all` | `--tools` + `--xrdp` (does not touch `~/htb`) |
| `--htbdir` | Delete `~/htb` and all box data — prompts first |

```sh
TARGET_USER=tom sudo -E ./htb-teardown.sh --all
```

## Notes and caveats

- **NodeSource on Trixie:** if NodeSource has no Trixie repo yet, the setup
  falls back to Debian's `nodejs`/`npm`, which is fine for Claude Code.
- **xrdp + XFCE black screen:** this VM is meant to be reached only over RDP.
  Do not also open a local console GUI session at the same time — xrdp and a
  local session competing for the same XFCE session can produce a black screen.
- **Idempotency:** the setup script strips and rewrites its own marked block in
  `.zshrc`, checks before re-cloning plugins, and skips already-installed pipx
  tools. Re-run it freely after editing the package list.
- **apt tolerance:** package names are checked against the repo before install,
  so a name that has drifted out of Trixie is skipped and logged rather than
  aborting the run.
