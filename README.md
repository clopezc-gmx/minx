# minx - minimal debian setup with dwm

This repo contains provisioning and runtime tools for a Debian 13 workstation in two flavors: a minimal dwm desktop for laptops, or a headless server.

## What gets installed

Pinned in `install/config/pinned_versions.txt`:

- **Suckless tools:** dwm, st, sent, slock (patched from `install/patches/`)
- **Editors and tools:** Vim, universal-ctags, shfmt, tmpi
- **Browser:** qutebrowser with the Dracula theme and pdf.js
- **Tasks and time:** Taskwarrior, Timewarrior
- **Writing:** LanguageTool with fastText, LaTeX snippets, 
- **Languages:** Go, nvm and Node.js
- **Fonts and themes:** JetBrains Mono (Nerd Font), Linux a11y sound theme
- **Other:** Spotify, LibreWolf, Calix

Design is around the following tools:

- vim 
- qutebrowser (qb.sh)
- neomutt
- khal with vdirsyncer, task- and timewarrior
- keepassxc

Some tools were installed manually since the required version is not available in Debian 13 packages, but I expect they will be included in newer releases.

## Structure

`minx` consists of two parts:

- **`install/`**: numbered scripts that set up a fresh Debian system, build pinned versions of third-party software from source, and install everything under `/opt/minx`.
- **`runtime/`**: the scripts and helpers used day to day on the installed system (launcher, lock screen, hooks, mail and task helpers).

> This is a personal setup, therefore it is shared as-is.
> It reflects my machines and preferences.
> If for whatever reason you want to use it, read the scripts before running them: many of them run as root.

## Requirements

- Debian 13 installed with `system-utils` only.
- A regular user with `sudo` access. The root scripts are run via `sudo`, and that user becomes the target user.
- Network access, and an SSH key for the remote server that stores large binary files (see [Configuration](#configuration))

## Repository layout

```text
minx/
├── install/
│   ├── config/
│   │   ├── minx.conf.example           # copy to minx.conf and edit
│   │   ├── minx.conf                   # machine-specific settings (local)
│   │   ├── template_minx_profile.sh    # template for /etc/profile.d
│   │   └── pinned_versions.txt         # pinned commits, versions, hashes
│   ├── patches/                        # patches for suckless tools and themes
│   ├── scripts/                        # numbered installation steps
│   │   ├── 00_root_init.sh
│   │   ├── ...
│   │   ├── 09_root_setup.sh
│   │   ├── check_updates.sh            # report newer upstream versions
│   │   ├── download_repos.sh
│   │   ├── installer.sh
│   │   ├── run.sh                      # utility script to run installation scripts
│   │   └── lib/                        # shared helpers (minx_*)
│   └── services/
│       ├── system/                     # systemd system units and dispatch
│       └── user/                       # systemd user services and timers
└── runtime/
    ├── system/                         # minx-control, minx-launcher, ...
    └── user/                           # user scripts, hooks, completion
```

## Installation

The scripts in `install/scripts/` are numbered in the order they run.
The name says who runs them: `root` scripts run with `sudo`, `user` scripts run as your regular user.
Each step is safe to re-run.

 | Script                           | Run as | Purpose                                       |
 | -------------------------------- | ------ | ------------------------------------          |
 | `00_root_init.sh`                | root   | initial system preparation                    |
 | `01_root_install_packages.sh`    | root   | APT packages, firmware, groups                |
 | `02_user_build_sucklesstools.sh` | user   | build and patch dwm, st, sent, slock          |
 | `03_root_install_suckless.sh`    | root   | install the suckless builds                   |
 | `04_root_install_external.sh`    | root   | external software installed as root           |
 | `05_user_install_external.sh`    | user   | external software in the user's home          |
 | `06_user_build_external.sh`      | user   | build external software from source (as user) |
 | `07_root_install_user_builds.sh` | root   | root install what step 06 built               |
 | `08_user_setup.sh`               | user   | user configuration                            |
 | `09_root_setup.sh`               | root   | root configuration                            |

Helpers: `download_repos.sh` fetches all sources, `installer.sh` holds the build and install logic used by the numbered steps, and `run.sh` is the entry point wrapper.

Run any script without arguments to list its options.

### Step 01: system packages

```bash
sudo ./install/scripts/01_root_install_packages.sh --run-update
sudo ./install/scripts/01_root_install_packages.sh --initial-setup
sudo ./install/scripts/01_root_install_packages.sh --install-firmware
sudo ./install/scripts/01_root_install_packages.sh --install-base
```

A headless server can stop after `--install-base`. A laptop continues with:

```bash
sudo ./install/scripts/01_root_install_packages.sh --install-dev
sudo ./install/scripts/01_root_install_packages.sh --install-desktop
sudo ./install/scripts/01_root_install_packages.sh --install-radio
sudo ./install/scripts/01_root_install_packages.sh --install-power
sudo ./install/scripts/01_root_install_packages.sh --install-latex   # optional, large
```

| Option               | What it does                                           |
| -------------------- | ------------------------------------------------------ |
| `--run-update`       | `apt` update, full upgrade, autoremove                 |
| `--initial-setup`    | timezone, keyboard, sudoers for the target user        |
| `--install-firmware` | firmware and CPU microcode                             |
| `--install-base`     | CLI system: git, tmux, mail tools, `pass`, ssh         |
| `--install-dev`      | compilers, Python, scientific libraries                |
| `--install-desktop`  | X11, audio/video, printing, removable media, GPU stack |
| `--install-radio`    | NetworkManager and Bluetooth                           |
| `--install-power`    | TLP (laptops only)                                     |
| `--install-latex`    | full TeX Live                                          |

### Downloading sources

```bash
./install/scripts/download_repos.sh
```

Clones every project at the commit pinned in `install/config/pinned_versions.txt` and downloads the archives, in parallel.
The fastText language model is fetched from your own server and verified against a pinned SHA-256 before it is accepted.

## Configuration

Copy `install/config/minx.conf.example` to `install/config/minx.conf` and edit it.
Settings are read as `MXC_*` variables and written to `/etc/profile.d/minx_profile.sh` as `MINX_*` variables, using `template_minx_profile.sh` as the source.

| Variable                   | Meaning                              |
| -------------------------- | ------------------------------------ |
| `MINX_INSTALLATION_DIR`    | install prefix (default `/opt/minx`) |
| `MINX_REPOS_DIR`           | where sources are cloned and built   |
| `MINX_USER_FILES_DIR`      | user files                           |
| `MINX_USER_REPOS_DIR`      | user repositories                    |
| `MINX_USER_NOTES_DIR`      | user notes                           |
| `MINX_REMOTE_SSH_SERVER`   | SSH host for remote storage          |
| `MINX_REMOTE_BINARIES_DIR` | remote directory with large binaries |
| `MINX_PROFILES_DIR`        | profiles directory (dotfiles)        |

### Pinned versions

`install/config/pinned_versions.txt` is a plain `key=value` file:

```text
commit_<name>=<hash>       # git projects, with url_<name>
version_<name>=<version>   # released versions
snapshot_<name>=<file>     # rolling downloads
sha256_<name>=<hash>       # integrity check for downloaded files
```

To update a project, change its entry and re-run `download_repos.sh`.
To see which pins are outdated, run:

```bash
./install/scripts/check_updates.sh
```

## Services

`install/services/` contains systemd units:

- **System:** a pre-shutdown unit and a sleep dispatch script
- **User:** `languagetool.service`, `wikiviewer.service`, `update_feeds` (service and timer), and `ssync-*` timers that synchronize calendar, files, mail, notes, `pass`, Taskwarrior and `ta`

## Runtime

After installation, `/opt/minx/runtime` contains:

- `system/bin`: `minx-control`, `minx-launcher`, `minx-lockscreen`, `minx-version`
- `system/completion` and `user/completion`: Bash completion
- `user/bin`: helpers such as `passmenu.sh`, `keepassmenu.sh`, `mailto.sh`, `myservices.sh`, `qb.sh`, `ssync.sh`
- `user/hooks`: sleep, shutdown, launcher and lock-screen hooks
- `user/lib` and `user/scripts`: Neomutt, Taskwarrior and Vim helpers

Check the installed version with:

```bash
minx-version
```

## Development

The repository uses [pre-commit](https://pre-commit.com/) with Markdown and prose linting. Commit messages follow `<type>(<scope>): <subject>`, for example `feat(install): add calix installer`.

```bash
pre-commit install
shellcheck -x install/scripts/*.sh
```

## Security notes

- The root scripts install packages, write to `/etc`, and edit sudoers. Review them first.
- Downloaded files that cannot be verified through TLS are accepted only if they match a SHA-256 pinned in `pinned_versions.txt`.
- Passwordless `sudo` is granted only for the Bluetooth, Wi-Fi and `rfkill` wrappers. Mount and umount stay off.

## License
