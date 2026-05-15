---
applyTo: "**/*.vim"
---

# VimScript Coding Instructions

## Style

- Variables: `snake_case`; script-local prefix `s:`, function-local prefix `l:` (always use `l:` for local vars).
- Public functions: `PascalCase` (e.g. `ARsync`, `LoadConf`, `ShowConf`).
- Script-local functions: `s:PascalCase` or `s:camelCase` (match existing style in the file).
- Use `abort` on every `function!` declaration to propagate exceptions.
- Prefer `==#` / `!=#` for string comparisons (case-sensitive, locale-safe).

## Security

- **Never use `eval()`** for parsing config values — use `json_decode()` via `s:ParseList()`.
- Escape user-supplied path values with `escape(val, '%#!')` before interpolating into strings.

## Async / Jobs

- Always use `arsync#job#start(cmd, opts)` — never call `jobstart`/`job_start` directly.
- Command arguments must be a **list**, not a string — use `+` to concatenate lists.
- Callbacks receive `(job_id, data, event_type)` where `event_type` is `'stdout'`, `'stderr'`, or `'exit'`.

## Quickfix

- Use named QF lists via `setqflist([], 'a', {'id': s:arsync_qfid, 'lines': data})` — never use `setqflist(data)` which clobbers the list.
- Sync output and git-status output use separate QF IDs (`s:arsync_qfid`, `s:git_status_qfid`).

## Status / Statusline

- All status updates go through `s:SetStatus(status)` — never assign `g:arsync_status` or `g:arsync_status_detail` directly.
- Always call `redrawstatus` after changing statusline variables.

## Config Parsing

- Config lives in `.vim-arsync` at the project root (or `.vim-arsync.<profile>`).
- List fields (`ignore_path`, `include_path`) are JSON arrays — parse with `s:ParseList()`.
- Scalar fields are plain strings — trim whitespace with `substitute()`.
- Lines starting with `#` and blank lines must be skipped.

## Port Handling

- `remote_port` is stored as a string from the config file; use `string(conf['remote_port'])` when building command lists to avoid type errors.
