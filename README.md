# vim-arsync :octopus:
A Vim/Neovim plugin for asynchronous rsync-based synchronisation between a local machine and a remote host over SSH. Install from `jenkeeri/vim-arsync`.
- Mirrors a remote build environment locally for IDE features (LSP, clangd, etc.)
- Multiple sync profiles, per-file/dir sync, post-sync remote command, Git status query, and statusline integration.

## Main features
- sync up or down project folder using rsync over SSH
- **automatic gitignore exclusion** — fetches the remote's `.gitignore` rules via `git ls-files` and caches them locally
- ignore certain files or folders based on configuration file
- asynchronous operation
- project based configuration file
- auto sync up on file save with optional debounce
- works with SSH keys
- run a remote build command after every up-sync and see compiler errors in the quickfix list
- dry-run preview before any destructive sync
- query remote git log and status without touching `.git/`
- per-file and per-directory sync for large projects
- multiple named profiles (e.g. `.vim-arsync.debug`, `.vim-arsync.release`)
- statusline integration via `g:arsync_status` and `g:arsync_last_sync_time`

## Installation
### Dependencies
- rsync
- *vim8* or *neovim*


### Using vim-plug
Place this in your .vimrc:

```vim
Plug 'jenkeeri/vim-arsync'
```

... then run the following in Vim:

```vim
:source %
:PlugInstall
```

### Using Packer

```lua
use { 'jenkeeri/vim-arsync' }
```

... then run the following in Vim:

```vim
:source %
:PackerSync
```

### Configuration
Create a ```.vim-arsync``` file on the root of your project that contains the following:

```
remote_host     example.com
remote_user     john
remote_port     22
remote_path     ~/temp/
local_path      /home/ken/temp/vuetest/
include_path    ["src/**","package.json"]
ignore_path     ["build/","test/"]
ignore_git      1
auto_sync_up    0
debounce_ms     500
sleep_before_sync 0
remote_options  -vazr
post_sync_cmd   make -C ~/temp/build -j8
warn_on_down    0
no_gitignore    0
```

Required fields are:
- ```remote_host```     remote host to connect (must have ssh enabled)
- ```remote_path```     remote folder to be synced

Optional fields are:
- ```remote_user```     username to connect with
- ```remote_port```     remote SSH port (default: 22)
- ```local_path```      local folder to be synced (defaults to the directory containing `.vim-arsync`)
- ```ignore_path```     list of ignored files/folders e.g. `["build/","test/"]`
- ```include_path```    list of included files/folders e.g. `["src/**","package.json"]` (passed as `--include`)
- ```ignore_git```      set to 1 to exclude `.git/` — prevents the remote's Git history from overwriting the local repo
- ```auto_sync_up```    set to 1 to automatically upload on every file save
- ```debounce_ms```     when `auto_sync_up` is enabled, coalesce rapid saves — the timer resets on each write and rsync only fires once the editing burst ends (e.g. `500` for 500 ms); takes precedence over `sleep_before_sync`
- ```sleep_before_sync``` delay in seconds before syncing — must be a positive integer (e.g. to wait for a build to finish); `0` or unset means sync immediately
- ```remote_options```  overrides the default rsync flags (default: `-vazr`; do **not** include `-e` as it is added automatically). To pass custom SSH options (e.g. identity file, ciphers), configure the host in `~/.ssh/config` instead.
- ```post_sync_cmd```   shell command run on the **remote host** via SSH after every successful up-sync. Output is piped into the quickfix list so compiler errors are immediately navigable. Example: `make -C ~/project/build -j8` or `ninja -C build/`. Only applies to remote mode.
- ```warn_on_down```    set to 1 to require interactive confirmation before any down-sync (`ARsyncDown` / `ARsyncDownDelete`)
- ```no_gitignore```    set to 1 to disable automatic gitignore-based exclusion (see below)

**Auto-managed fields** (do not edit manually):
- ```_cached_git_excludes``` JSON array of patterns fetched from the remote's `.gitignore` via `:ARsyncRefreshIgnore`

**Notes:**
- Lines starting with `#` are treated as comments and ignored.
- Blank lines are ignored.
- `-e 'ssh -p PORT'` is always added automatically — do not include `-e` in `remote_options`.

## Gitignore-based exclusion

By default, the plugin will warn you on first sync if no cached gitignore excludes exist. Run:

```vim
:ARsyncRefreshIgnore
```

This SSHs to the remote, runs `git ls-files --others --ignored --exclude-standard --directory`, and caches the result as `_cached_git_excludes` in your `.vim-arsync` file. On subsequent syncs, these patterns are automatically applied as `--exclude` flags to rsync.

**When to refresh:** Run `:ARsyncRefreshIgnore` after modifying `.gitignore` on the remote or after switching branches.

**Opting out:** Set `no_gitignore 1` in `.vim-arsync` to disable this feature entirely.

## Usage
If ```auto_sync_up``` is set to 1, the plugin will automatically run `:ARsyncUp` every time a
buffer is saved. The auto-sync hook is registered exactly once per project/directory, so opening
many buffers will not cause repeated or duplicated syncs.

Use `debounce_ms` to avoid firing rsync on every keystroke-triggered save when working with
tools like auto-save plugins or when running `:bufdo`.

### Commands

- ```:ARshowConf``` shows the detected configuration and the resolved rsync command for the current project
- ```:ARsyncUp``` uploads local files to the remote
- ```:ARsyncUpDelete``` uploads local files to the remote and **deletes remote files** that do not exist locally (use with care)
- ```:ARsyncDown``` downloads remote files to local
- ```:ARsyncDownDelete``` downloads remote files to local and **deletes local files** that do not exist on the remote — use this to fully mirror the remote and clean the local project state
- ```:ARsyncDryRun``` runs rsync with `--dry-run --itemize-changes` and shows exactly which files *would* be transferred — safe to run at any time
- ```:ARsyncFile``` uploads only the file in the current buffer
- ```:ARsyncDir``` uploads only the directory containing the current buffer
- ```:ARgitStatus``` SSHs to the remote and shows `git log --oneline -5` and `git status --short` in the quickfix window — no files are transferred
- ```:ARsyncRefreshIgnore``` fetches the list of git-ignored files/dirs from the remote and caches it in `.vim-arsync`
- ```:ARsyncProfile <name>``` switches the active profile (reads `.vim-arsync.<name>` instead of `.vim-arsync`); pass an empty string to revert to the default

Commands can be mapped to keyboard shortcuts to enhance operations:

```vim
nnoremap <leader>su :ARsyncUp<CR>
nnoremap <leader>sd :ARsyncDown<CR>
nnoremap <leader>sD :ARsyncDownDelete<CR>
nnoremap <leader>sf :ARsyncFile<CR>
nnoremap <leader>sr :ARsyncDryRun<CR>
nnoremap <leader>sg :ARgitStatus<CR>
nnoremap <leader>si :ARsyncRefreshIgnore<CR>
```

### Statusline integration

The plugin updates the following global variables after every sync:

| Variable | Values |
|---|---|
| `g:arsync_status` | `''` (idle), `'syncing'`, `'ok'`, `'error'` |
| `g:arsync_status_detail` | Human-readable string combining direction symbol and target, e.g. `'↑ user@host'`, `'↓! user@host'`, `'~ user@host'`, `'↑ file.cpp'`. Empty when idle. |
| `g:arsync_last_sync_time` | Last successful sync time as `HH:MM:SS`, or `''` |

After a sync completes (`'ok'` or `'error'`), the status automatically resets to `''` after
`g:arsync_ok_duration` seconds (default: **5**). Set it in your vimrc to customise:

```vim
let g:arsync_ok_duration = 8   " show result for 8 s, then clear
let g:arsync_ok_duration = 0   " never auto-clear
```

Direction symbols used in `g:arsync_status_detail`:

| Symbol | Meaning |
|---|---|
| `↑` | Upload (`:ARsyncUp`, `:ARsyncFile`, `:ARsyncDir`) |
| `↑!` | Upload + delete (`:ARsyncUpDelete`) |
| `↓` | Download (`:ARsyncDown`) |
| `↓!` | Download + delete (`:ARsyncDownDelete`) |
| `~` | Dry-run preview (`:ARsyncDryRun`) |

Example for **lualine** using `g:arsync_status_detail`:

```lua
sections = {
  lualine_x = {
    { function()
        local s = vim.g.arsync_status
        local d = vim.g.arsync_status_detail or ''
        if s == 'syncing' then return '⟳ ' .. d
        elseif s == 'ok'  then return '✓ ' .. d
        elseif s == 'error' then return '✗ ' .. d
        else return '' end
      end },
  },
}
```

Example for a classic **Vim statusline**:

```vim
function! ArsyncStatusline() abort
  let s = g:arsync_status
  let d = g:arsync_status_detail
  if s ==# 'syncing' | return '⟳ ' . d
  elseif s ==# 'ok'  | return '✓ ' . d
  elseif s ==# 'error' | return '✗ ' . d
  else | return '' | endif
endfunction
set statusline+=\ %{ArsyncStatusline()}
```

### Multiple profiles

Create `.vim-arsync.debug` and `.vim-arsync.release` in your project root with different
`remote_path` or `post_sync_cmd` values, then switch at runtime:

```vim
:ARsyncProfile debug
:ARsyncProfile release
:ARsyncProfile          " revert to default .vim-arsync
```

## TODO

- [ ] run more tests
- [ ] deactivate auto sync on error

## Acknowledgements

This plugin was inspired by [vim-hsftp](https://github.com/hesselbom/vim-hsftp) but vim-arsync offers more (rsync, ignore, async...).

## Similar projects

- [coffebar/transfer.nvim](https://github.com/coffebar/transfer.nvim)
- [OscarCreator/rsync.nvim](https://github.com/OscarCreator/rsync.nvim)
