# Copilot Documentation — vim-arsync

> This file is intended to track the progress of the project.
> Update it after every meaningful session.

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
1. The **Improvement Roadmap** to mark completed items or add new ones.
2. Any new **Known Issues** discovered.
