# tmux workspace (tws)

A shell script to create/manage tmux sessions & windows with a simple YAML file.

## Quick Start

Create a config file in `~/.config/tmux/workspace.yaml`, example:

```yaml
projects:
  project1: ~/Documents/source/work/proj-1
  project2: ~/Documents/source/work/proj-2.0
  project3: ~/Documents/source/work/proj3

configs:
  home: ~
  nvim: ~/.config/nvim
```

Start the workspace (see [Installation](#installation) below):

```sh
tws
```

Starting the workspace will create a session called `projects` with windows:

- `project1` with path `~/Documents/source/work/proj-1`
- `project2` with path `~/Documents/source/work/proj-2.0`
- `project3` with path `~/Documents/source/work/proj3`

and a session called `configs` with windows:

- `home` with path `~`
- `nvim` with path `~/.config/nvim`

For each session, the current window will be set to the first window in the
YAML file, and the second window to the second window in the YAML file so that
`{PREFIX}l` will switch between the first two windows.

The script will then attach to the first (`projects`) session.

## Installation

1. Ensure tmux is installed and on PATH
2. Save script as tws.sh and make executable

```sh
chmod +x ./tws.sh
```

3. For convenience, add an alias to your shell configuration

```sh
# ~/.zshrc or ~/.bashrc
alias tws="{PATH_TO_SCRIPT}/tws.sh"
```

## Usage

- Default (up/attach): if no server, create from YAML & attach, otherwise attach
  - `tws` (equivalent to: `tws.sh`)
- Select socket: -L name (for separate servers)
  - `tws -L dev`
  - `tws -L ci`
- Restart from YAML then attach
  - `tws restart`
- Kill server (all sessions/windows)
  - `tws kill`
- Snapshot current server to YAML (backs up to workspace.backup.yaml)
  - `tws snapshot` (writes to ~/.config/tmux/workspace.yaml)
  - `tws snapshot /path/to/file.yaml`
- List current sessions/windows
  - `tws ls`
- Diff YAML vs current server windows
  - `tws diff`
    - prints windows that are in both YAML and server
    - prints windows that are only in YAML in red
    - prints windows that are only on server in green
    - prints windows whose order has changed in red (old) and green (new)
    - prints windows whose names match but have different paths in yellow
- Edit the YAML config in your $EDITOR (creates file if missing)
  - `tws edit`
