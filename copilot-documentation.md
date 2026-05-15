# Copilot Documentation — vim-arsync

> This file is intended to be read at the start of every Copilot conversation to provide
> full context on the project, its architecture, and its evolution. Update it after every
> meaningful session.

---

## Project Overview

**Repository:** `jenkeeri/vim-arsync`

A Vim/Neovim plugin for **asynchronous rsync-based synchronisation** between a local machine
and a remote host (or between two local paths). The primary use-case for this plugin's author is:

- **Local (edit):** MacBook running Neovim
- **Remote (build/run):** Linux host where all C++ compilation happens
- Workflow: edit on Mac → auto-sync to Linux → build remotely → optionally pull results back

---

## Repository Layout

```
vim-arsync/
├── plugin/
│   └── vim-arsync.vim          # Main plugin file: config parsing, rsync command builder,
│                               #   async job dispatch, auto-sync autocmds, user commands
├── autoload/
│   └── arsync/
│       └── job.vim             # Bundled async job library
│                               #   Abstracts nvimjob / vimjob differences
├── README.md
├── LICENSE
└── copilot-documentation.md    # This file
```

---

## Key Architecture Points

### `plugin/vim-arsync.vim`

| Function | Purpose |
|---|---|
| `LoadConf()` | Parses `.vim-arsync` (or profile) config file (walks up from cwd), returns a dict. Handles comments (`#`), blank lines, list fields (`ignore_path`, `include_path`). Profile support via `g:arsync_profile`. |
| `s:BuildRsyncCmd(dir, conf)` | Builds the rsync command list for any direction. Shared by `ARsync()` and `ShowConf()`. Applies all filters. |
| `ARsync(direction)` | Entry point for `up`, `down`, `upDelete`, `downDelete`, `dryRun`. Checks concurrency guard, confirmation prompt, builds and dispatches job. |
| `JobHandler(...)` | Callback for stdout/stderr/exit. Streams output to quickfix; opens on error or dry-run; calls `s:SetStatus()` to update statusline variables, trigger `redrawstatus`, and schedule auto-reset. |
| `s:PostSyncHandler(...)` | Streams `post_sync_cmd` SSH output to quickfix, opens on error. |
| `s:GitStatusHandler(...)` | Streams `ARgitStatus` output to its own quickfix list (`s:git_status_qfid`). |
| `AutoSync()` | Registers (or clears) `BufWritePost`/`FileWritePost` autocmd. Supports `debounce_ms`, `sleep_before_sync`. Re-evaluated on `VimEnter` and `DirChanged`. |
| `ShowConf()` | `:ARshowConf` — pretty-prints config dict and resolved rsync command. |
| `ARsyncDryRun()` | Calls `ARsync('dryRun')`. |
| `ARgitStatus()` | SSHs to remote, runs `git log + git status`, output to separate QF list. |
| `ARsyncFile()` | Syncs only the current buffer file to its corresponding remote path. |
| `ARsyncDir()` | Syncs only the directory containing the current buffer. |
| `ARsyncProfile(name)` | Sets `g:arsync_profile` and re-runs `AutoSync()`. |
| `s:DebouncedSync()` | Debounce wrapper: resets timer on each save, fires `ARsync('up')` after `debounce_ms`. |
| `s:ParseList(raw)` | Safe JSON-array parser replacing `eval()` for list config fields. |

### `autoload/arsync/job.vim`

Thin wrapper around Neovim's `jobstart` / Vim's `job_start`. Provides:
- `arsync#job#start(cmd, opts)` — start a job, returns job id
- `arsync#job#stop(jobid)` — stop a job
- Unified `on_stdout`, `on_stderr`, `on_exit` callback interface

### `.vim-arsync` Config File

Placed at the root of a project. Key fields:

| Field | Default | Notes |
|---|---|---|
| `remote_host` | *(required)* | SSH hostname |
| `remote_path` | *(required)* | Path on remote |
| `remote_user` | — | SSH username |
| `remote_port` | 22 | SSH port |
| `remote_passwd` | — | Plaintext password (requires `sshpass`) |
| `local_path` | dir of `.vim-arsync` | Local root |
| `ignore_path` | — | List of rsync `--exclude` patterns |
| `include_path` | — | List of rsync `--include` patterns |
| `ignore_dotfiles` | 0 | Exclude `.*` when `1` |
| `ignore_git` | 0 | Exclude `.git/` when `1` (finer-grained than `ignore_dotfiles`) |
| `auto_sync_up` | 0 | Auto-upload on every buffer write |
| `debounce_ms` | 0 | Coalesce rapid saves; takes precedence over `sleep_before_sync` |
| `remote_or_local` | `remote` | `remote` = SSH, `local` = local fs |
| `sleep_before_sync` | 0 | Delay in seconds before rsync fires |
| `remote_options` | `-vazr` | rsync flags for remote mode |
| `local_options` | `-var` | rsync flags for local mode |
| `post_sync_cmd` | — | Shell command run on remote after successful up-sync; output → quickfix |
| `warn_on_down` | 0 | Prompt for confirmation before any down-sync |

---

## Session History

### Session 1 — 2026-04-23 (Initial Analysis & Roadmap)

**Goal:** Understand the plugin and plan improvements for a C++ Mac↔Linux developer workflow.

**Key context shared by the developer:**
- Uses Neovim on MacBook to edit, Linux host to compile C++.
- Wants Git information but syncing `.git/` causes conflicts (commits on Linux overwrite local state).
- Needs improvements that help day-to-day C++ development over rsync.

**Outcome:** Created this documentation file. Improvement roadmap outlined below (see next section).

---

### Session 2 — 2026-04-23 (Full Roadmap Implementation)

**Goal:** Implement the entire improvement roadmap from Session 1.

**Changes made:**
- `plugin/vim-arsync.vim` — complete rewrite implementing all features below
- `README.md` — all new config fields, commands, statusline docs, profile docs
- `copilot-documentation.md` — updated architecture table, config table, roadmap status

**Features implemented:**
1. `s:ParseList()` — safe `json_decode`-based list parser replacing `eval()` (security fix)
2. `s:arsync_running` concurrency guard — prevents parallel rsync jobs
3. `s:arsync_qfid` / `s:git_status_qfid` — moved QF IDs to script-local scope
4. `s:BuildRsyncCmd()` — extracted command builder shared by `ARsync()` and `ShowConf()`
5. `ignore_git` config option — excludes `.git/` without clobbering other dotfiles
6. `post_sync_cmd` — SSH command after successful up-sync, output piped to quickfix
7. `:ARsyncDryRun` — `--dry-run --itemize-changes` preview
8. `:ARgitStatus` — SSH query of remote git log + status into a dedicated QF list
9. `g:arsync_status` / `g:arsync_last_sync_time` — statusline integration variables
10. `debounce_ms` — coalesces rapid saves into one rsync invocation
11. Multiple profiles — `g:arsync_profile` + `:ARsyncProfile <name>` command
12. `:ARsyncFile` / `:ARsyncDir` — per-file and per-directory sync
13. `warn_on_down` — interactive confirmation before destructive down-syncs
14. `ShowConf()` — pretty-printed config table + resolved rsync command display
15. `remote_host` check now correctly skipped for `remote_or_local = local` mode

---

### Session 3 — 2026-04-24 (Statusline Improvements)

**Goal:** Make the statusline integration more informative and fix the status not resetting after sync.

**Root causes identified:**
1. `redrawstatus` was never called → statusline never refreshed while Vim was idle
2. `g:arsync_status` stayed at `'ok'`/`'error'` indefinitely — no auto-reset
3. No direction or target info in the status (users couldn't tell what was syncing or where)

**Changes made:**
- `plugin/vim-arsync.vim`:
  - Added `g:arsync_status_detail` — human-readable string with direction symbol + target
    (e.g. `'↑ user@host'`, `'↓! user@host'`, `'↑ file.cpp'`, `'~ user@host'`)
  - Added `g:arsync_ok_duration` — seconds before `'ok'`/`'error'` auto-resets to `''` (default: 5; set to 0 to disable)
  - Added `s:SetStatus(status)` — central helper that updates both variables, calls `redrawstatus`, and schedules the reset timer
  - Added `s:ResetStatus(timer)` — timer callback that clears status variables and calls `redrawstatus`
  - `ARsync()`, `ARsyncFile()`, `ARsyncDir()` now set `s:arsync_direction_label` and `s:arsync_target_label` before starting the job
  - All direct `let g:arsync_status = ...` assignments replaced with `call s:SetStatus(...)`
- `README.md`:
  - Expanded statusline section: new variables table, direction symbol table, `g:arsync_ok_duration` config docs
  - Updated lualine example to use `g:arsync_status_detail`
  - Added classic Vim statusline example

---

## Improvement Roadmap

Items are grouped by theme. ✅ = implemented.

### 🔴 High Priority

#### ✅ 1. `ignore_git` config option (Git-safe syncing)
#### ✅ 2. Remote command execution after sync (`post_sync_cmd`)
#### ✅ 3. Dry-run preview mode (`:ARsyncDryRun`)

### 🟡 Medium Priority

#### ✅ 4. Remote Git status display (`:ARgitStatus`)
#### ✅ 5. Statusline / notification integration (`g:arsync_status`, `g:arsync_last_sync_time`)
#### ✅ 6. Debounce / coalesce rapid saves (`debounce_ms`)
#### ✅ 7. Multiple profile support (`:ARsyncProfile <name>`)

### 🟢 Lower Priority / Nice to Have

#### ✅ 8. Per-file / per-directory sync (`:ARsyncFile`, `:ARsyncDir`)
#### ✅ 9. Conflict / newer-file warning (`warn_on_down`)
#### ✅ 10. `:ARshowConf` pretty-print + resolved command display

---

## Known Issues / Tech Debt

- ~~`eval()` is used to parse `ignore_path` / `include_path` list values~~ **Fixed** — replaced with `s:ParseList()` using `json_decode()`.
- ~~No lock/guard against concurrent rsync jobs~~ **Fixed** — `s:arsync_running` flag.
- ~~`g:arsync_qfid` global breaks with multiple projects in splits~~ **Fixed** — moved to `s:arsync_qfid` (script-local).
- ~~`g:arsync_status` never resets after sync completes~~ **Fixed** — `s:SetStatus()` schedules a `timer_start` reset and calls `redrawstatus`.
- ~~No direction or target information in the statusline~~ **Fixed** — `g:arsync_status_detail` carries direction symbol + target label.
- Auto-sync group is fully replaced on every `DirChanged` / `VimEnter`, which means `g:arsync_debounce_ms` and `g:arsync_sleep_time` are still globals — if two projects use different values in a single session, the last `AutoSync()` call wins. Full per-project isolation would require keying state by `local_path`.

---

## How to Read This File

At the start of a new Copilot session, paste the contents of this file or say:
> "Read copilot-documentation.md and use it as context for this session."

After completing work in a session, update:
1. The **Session History** section with a brief summary of what was done.
2. The **Improvement Roadmap** to mark completed items or add new ones.
3. Any new **Known Issues** discovered.
