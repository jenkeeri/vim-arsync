# GitHub Copilot Workspace Instructions — vim-arsync

## Project Identity

**Repo:** `jenkeeri/vim-arsync` — personal fork of `kenn7/vim-arsync`.  
A Vim/Neovim plugin providing **asynchronous rsync-based synchronisation** between a local machine and a remote host (or two local paths).

**Primary use-case:** Edit on MacBook (Neovim) → auto-sync to Linux host → build C++ remotely → optionally pull results back.

---

## Repository Layout

```
vim-arsync/
├── plugin/vim-arsync.vim   # Main plugin: config parsing, rsync command builder,
│                           #   async job dispatch, autocmds, user commands
├── autoload/arsync/job.vim # Bundled async job shim (prabirshrestha/async.vim)
│                           #   Abstracts nvimjob / vimjob differences
├── README.md
├── LICENSE
└── copilot-documentation.md  # Living context document — update after every session
```

---

## Key Architecture

### `plugin/vim-arsync.vim`

| Symbol | Role |
|---|---|
| `LoadConf()` | Parses `.vim-arsync` (or profile variant); handles `#` comments, blank lines, list fields via `s:ParseList()` |
| `s:BuildRsyncCmd(dir, conf)` | Builds rsync command list for any direction; shared by `ARsync()` and `ShowConf()` |
| `ARsync(direction)` | Entry point for `up/down/upDelete/downDelete/dryRun`; concurrency guard via `s:arsync_running` |
| `JobHandler(...)` | Async callback — streams to quickfix; calls `s:SetStatus()`; dispatches `post_sync_cmd` if set |
| `s:SetStatus(status)` | Central status setter: updates `g:arsync_status` + `g:arsync_status_detail`, fires `redrawstatus`, schedules auto-reset timer |
| `AutoSync()` | Registers `BufWritePost`/`FileWritePost` autocmd; supports `debounce_ms` and `sleep_before_sync` |

### `autoload/arsync/job.vim`

Thin shim over Neovim `jobstart` / Vim `job_start`.  
API: `arsync#job#start(cmd, opts)` / `arsync#job#stop(jobid)`.  
Do **not** call `jobstart`/`job_start` directly — always go through this shim.

---

## Coding Conventions

- **VimScript style:** `snake_case` for variables, `PascalCase` for public functions, `s:snake_case` for script-local functions/variables.
- **Script-local state** (concurrency guard, QF IDs, timer IDs, direction/target labels) lives in `s:` variables at the top of `vim-arsync.vim`.
- **Never use `eval()`** — use `s:ParseList()` with `json_decode()` for list config fields.
- **Quickfix management:** use `setqflist([], 'a', {'id': s:arsync_qfid, ...})` pattern; keep sync output and git-status output in separate QF lists (`s:arsync_qfid` / `s:git_status_qfid`).
- **Statusline updates:** always go through `s:SetStatus()`; never write `g:arsync_status` or `g:arsync_status_detail` directly from other functions.
- **Port handling:** always convert `remote_port` with `string()` when building SSH command lists.
- **SSH command construction:** `-e 'ssh -p PORT'` is added automatically by `s:BuildRsyncCmd` — never add it manually elsewhere.
- **Config file:** `.vim-arsync` at project root (or `.vim-arsync.<profile>` for profiles). Required fields: `remote_host`, `remote_path`.

---

## Config Fields Reference

| Field | Default | Notes |
|---|---|---|
| `remote_host` | *(required for remote)* | SSH hostname |
| `remote_path` | *(required)* | Path on remote |
| `remote_user` | — | SSH username |
| `remote_port` | 22 | SSH port |
| `remote_passwd` | — | Plaintext password (requires `sshpass`) |
| `local_path` | dir of `.vim-arsync` | Local root |
| `ignore_path` | — | JSON array of rsync `--exclude` patterns |
| `include_path` | — | JSON array of rsync `--include` patterns |
| `ignore_dotfiles` | 0 | Exclude `.*` when 1 |
| `ignore_git` | 0 | Exclude `.git/` only (finer-grained than `ignore_dotfiles`) |
| `auto_sync_up` | 0 | Auto-upload on every buffer write |
| `debounce_ms` | 0 | Coalesce rapid saves; takes precedence over `sleep_before_sync` |
| `remote_or_local` | `remote` | `remote` = SSH, `local` = local fs |
| `sleep_before_sync` | 0 | Delay in seconds before rsync fires |
| `remote_options` | `-vazr` | rsync flags for remote mode |
| `local_options` | `-var` | rsync flags for local mode |
| `post_sync_cmd` | — | Shell command run on remote after successful up-sync; output → quickfix |
| `warn_on_down` | 0 | Prompt for confirmation before any down-sync |

---

## Statusline Variables

| Variable | Values |
|---|---|
| `g:arsync_status` | `''` (idle), `'syncing'`, `'ok'`, `'error'` |
| `g:arsync_status_detail` | Direction symbol + target, e.g. `'↑ user@host'`, `'↓! user@host'` |
| `g:arsync_last_sync_time` | `HH:MM:SS` of last successful sync, or `''` |
| `g:arsync_ok_duration` | Seconds before ok/error auto-resets (default 5; 0 = never) |

---

## Active Commands

`:ARshowConf` · `:ARsyncUp` · `:ARsyncUpDelete` · `:ARsyncDown` · `:ARsyncDownDelete`  
`:ARsyncDryRun` · `:ARsyncFile` · `:ARsyncDir` · `:ARgitStatus` · `:ARsyncProfile <name>`

---

## Living Context

`copilot-documentation.md` contains full session history, the improvement roadmap, and known issues/tech debt.  
**Read it before making any non-trivial change.**  
**Update it after every meaningful session.**
