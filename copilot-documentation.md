# Copilot Documentation — vim-arsync

> This file is intended to track the progress of the project.
> Update it after every meaningful session.

---

## Session: 2026-05-27 — Audit, Trim & Gitignore Feature

### Changes Made

**Removed features:**
- `ignore_dotfiles` — config field and `--exclude '.*'` logic in `s:BuildRsyncCmd`
- `sshpass` / `remote_passwd` — all password-based auth code from `BuildRsyncCmd`, `ARsync`, `ARsyncFile`, `ARsyncDir`
- Local-to-local sync mode (`remote_or_local=local`) — all local branches from `BuildRsyncCmd`, `ARsyncFile`, `ARsyncDir`; removed `local_options` and `remote_or_local` defaults from `LoadConf()`

**Added:**
- **Gitignore-based exclusion** — new `:ARsyncRefreshIgnore` command SSHs to remote, runs `git ls-files --others --ignored --exclude-standard --directory`, caches result as `_cached_git_excludes` JSON array in `.vim-arsync`
- `_cached_git_excludes` patterns applied as `--exclude` flags in `s:BuildRsyncCmd`
- `no_gitignore` opt-out config field
- Warning on first sync if no cached excludes exist
- New functions: `s:WriteGitExcludesToConfig()`, `s:RefreshIgnoreHandler()`, `ARsyncRefreshIgnore()`
- New script-local state: `s:git_excludes_output`

**Simplified:**
- `s:BuildRsyncCmd` — removed all `remote_or_local` branching, now always remote/SSH
- `ARsync()` — removed sshpass validation, simplified remote_host check
- `ARsyncFile()` / `ARsyncDir()` — removed local mode branches and sshpass handling
- `ShowConf()` — simplified condition for showing resolved command
- `LoadConf()` — removed `remote_or_local` and `local_options` defaults

---

## Known Issues / Tech Debt

- ~~`eval()` is used to parse `ignore_path` / `include_path` list values~~ **Fixed** — replaced with `s:ParseList()` using `json_decode()`.
- ~~No lock/guard against concurrent rsync jobs~~ **Fixed** — `s:arsync_running` flag.
- ~~`g:arsync_qfid` global breaks with multiple projects in splits~~ **Fixed** — moved to `s:arsync_qfid` (script-local).
- ~~`g:arsync_status` never resets after sync completes~~ **Fixed** — `s:SetStatus()` schedules a `timer_start` reset and calls `redrawstatus`.
- ~~No direction or target information in the statusline~~ **Fixed** — `g:arsync_status_detail` carries direction symbol + target label.
- Auto-sync group is fully replaced on every `DirChanged` / `VimEnter`, which means `g:arsync_debounce_ms` and `g:arsync_sleep_time` are still globals — if two projects use different values in a single session, the last `AutoSync()` call wins. Full per-project isolation would require keying state by `local_path`.

---

After completing work in a session, update:
1. The **Session log** above with a dated entry of what was done.
2. Any new **Known Issues** discovered.
