" Vim plugin to handle async rsync synchronisation between hosts
" Title: vim-arsync
" Author: Ēriks Jenkēvics
" Date: 2019-2026
" License: MIT

if exists('g:loaded_vim_arsync')
    finish
endif
let g:loaded_vim_arsync = 1

" ---------- Script-local state ----------
let s:arsync_running             = 0   " concurrency guard
let s:arsync_qfid                = 0   " quickfix list id for sync output
let s:git_status_qfid            = 0   " quickfix list id for :ARgitStatus
let s:arsync_debounce_timer      = -1  " timer id for debounce
let s:arsync_post_job_cmd        = []  " SSH command to run after a successful up-sync
let s:arsync_is_dry_run          = 0   " 1 when the current job is a dry-run
let s:arsync_direction_label     = ''  " direction symbol for g:arsync_status_detail
let s:arsync_target_label        = ''  " target (host/file/dir) for g:arsync_status_detail
let s:arsync_status_reset_timer  = -1  " timer id for auto-reset of ok/error status
let s:git_excludes_output        = []  " accumulator for :ARsyncRefreshIgnore SSH output

" Public variables for statusline / notification integration.
" g:arsync_status        — '' (idle), 'syncing', 'ok', 'error'
" g:arsync_status_detail — human-readable string: direction symbol + target, e.g. '↑ user@host'
" g:arsync_last_sync_time — last successful sync time as HH:MM:SS, or ''
" g:arsync_ok_duration   — seconds before 'ok'/'error' auto-resets to '' (0 = never, default 5)
let g:arsync_status         = ''
let g:arsync_status_detail  = ''
let g:arsync_last_sync_time = ''
if !exists('g:arsync_ok_duration')
    let g:arsync_ok_duration = 5
endif

" ---------- Helpers ----------

" Resets the statusline state to idle; called by a timer after ok/error.
function! s:ResetStatus(timer) abort
    let s:arsync_status_reset_timer = -1
    let g:arsync_status        = ''
    let g:arsync_status_detail = ''
    redrawstatus
endfunction

" Central status setter: updates g:arsync_status + g:arsync_status_detail,
" fires redrawstatus, and schedules an auto-reset for ok/error states.
function! s:SetStatus(status) abort
    if s:arsync_status_reset_timer != -1
        call timer_stop(s:arsync_status_reset_timer)
        let s:arsync_status_reset_timer = -1
    endif
    let g:arsync_status = a:status
    if a:status ==# 'syncing'
        let g:arsync_status_detail = s:arsync_direction_label . s:arsync_target_label
    elseif a:status ==# 'ok'
        let g:arsync_last_sync_time = strftime('%H:%M:%S')
        let g:arsync_status_detail  = s:arsync_direction_label . ' ' . g:arsync_last_sync_time
        if g:arsync_ok_duration > 0
            let s:arsync_status_reset_timer = timer_start(
                        \ g:arsync_ok_duration * 1000, function('s:ResetStatus'))
        endif
    elseif a:status ==# 'error'
        let g:arsync_status_detail = s:arsync_direction_label . ' error'
        if g:arsync_ok_duration > 0
            let s:arsync_status_reset_timer = timer_start(
                        \ g:arsync_ok_duration * 1000, function('s:ResetStatus'))
        endif
    elseif a:status ==# ''
        let g:arsync_status_detail = ''
    endif
    redrawstatus
endfunction

" Safe list parser — replaces eval() on ignore_path / include_path.
" Accepts JSON-array syntax: ["a","b","c"]
function! s:ParseList(raw) abort
    try
        let l:result = json_decode(a:raw)
        if type(l:result) == type([])
            return l:result
        endif
    catch
    endtry
    return []
endfunction

" Returns 1 when a .vim-arsync (or profile) config exists in the directory tree.
function! ShouldSync() abort
    let l:suffix = exists('g:arsync_profile') && !empty(g:arsync_profile)
                \ ? '.' . g:arsync_profile : ''
    return !empty(findfile('.vim-arsync' . l:suffix, '.;'))
                \ || !empty(findfile('.vim-arsync', '.;'))
endfunction

" Parse and return the config dict from .vim-arsync (or active profile file).
function! LoadConf() abort
    let l:conf_dict = {}
    let l:suffix = exists('g:arsync_profile') && !empty(g:arsync_profile)
                \ ? '.' . g:arsync_profile : ''
    let l:config_file = findfile('.vim-arsync' . l:suffix, '.;')
    " Fall back to the default config file when the profile file is not found
    if empty(l:config_file) && !empty(l:suffix)
        let l:config_file = findfile('.vim-arsync', '.;')
    endif

    if strlen(l:config_file) > 0
        let l:conf_options = readfile(l:config_file)
        for i in l:conf_options
            " Skip blank lines and lines starting with #
            let l:trimmed = substitute(i, '^\s*\(.\{-}\)\s*$', '\1', '')
            if empty(l:trimmed) || l:trimmed[0] ==# '#'
                continue
            endif
            let l:sep = stridx(l:trimmed, ' ')
            " l:sep == -1: no separator; l:sep == 0: empty key — both invalid
            if l:sep <= 0
                continue
            endif
            let l:var_name  = l:trimmed[0:l:sep-1]
            let l:raw_value = substitute(l:trimmed[l:sep+1:], '^\s*\(.\{-}\)\s*$', '\1', '')
            if l:var_name ==# 'ignore_path' || l:var_name ==# 'include_path'
                        \ || l:var_name ==# '_cached_git_excludes'
                let l:var_value = s:ParseList(l:raw_value)
            else
                let l:var_value = escape(l:raw_value, '%#!')
            endif
            let l:conf_dict[l:var_name] = l:var_value
        endfor
    endif
    if !has_key(l:conf_dict, 'local_path')
        let l:conf_dict['local_path'] = fnamemodify(l:config_file, ':p:h')
    endif
    if !has_key(l:conf_dict, 'remote_port')
        let l:conf_dict['remote_port'] = 22
    endif
    if !has_key(l:conf_dict, 'remote_options')
        let l:conf_dict['remote_options'] = '-vazr'
    endif
    return l:conf_dict
endfunction

" Build and return the rsync command list for the given direction using conf_dict.
" Applies all filter flags (include_path, ignore_path, ignore_git, _cached_git_excludes).
" Returns [] for unknown direction combinations.
function! s:BuildRsyncCmd(direction, conf_dict) abort
    let l:remote_opts = split(a:conf_dict['remote_options'])
    let l:ssh_cmd     = 'ssh -p ' . a:conf_dict['remote_port']
    let l:user_passwd = has_key(a:conf_dict, 'remote_user')
                \ ? a:conf_dict['remote_user'] . '@' : ''
    let l:remote = l:user_passwd . a:conf_dict['remote_host'] . ':' . a:conf_dict['remote_path']

    let l:cmd = []
    if a:direction ==# 'down'
        let l:cmd = ['rsync', '--prune-empty-dirs'] + l:remote_opts + ['-e', l:ssh_cmd, l:remote . '/', a:conf_dict['local_path'] . '/']
    elseif a:direction ==# 'up'
        let l:cmd = ['rsync'] + l:remote_opts + ['-e', l:ssh_cmd, a:conf_dict['local_path'] . '/', l:remote . '/']
    elseif a:direction ==# 'upDelete'
        let l:cmd = ['rsync', '--delete'] + l:remote_opts + ['-e', l:ssh_cmd, a:conf_dict['local_path'] . '/', l:remote . '/']
    elseif a:direction ==# 'downDelete'
        let l:cmd = ['rsync', '--delete', '--prune-empty-dirs'] + l:remote_opts + ['-e', l:ssh_cmd, l:remote . '/', a:conf_dict['local_path'] . '/']
    elseif a:direction ==# 'dryRun'
        let l:cmd = ['rsync', '--dry-run', '--itemize-changes'] + l:remote_opts + ['-e', l:ssh_cmd, a:conf_dict['local_path'] . '/', l:remote . '/']
    endif

    if empty(l:cmd)
        return []
    endif

    if has_key(a:conf_dict, 'include_path')
        for l:file in a:conf_dict['include_path']
            let l:cmd += ['--include', l:file]
        endfor
    endif
    if has_key(a:conf_dict, 'ignore_path')
        for l:file in a:conf_dict['ignore_path']
            let l:cmd += ['--exclude', l:file]
        endfor
    endif
    " ignore_git excludes .git/ without touching other dotfiles like .clang-format
    if has_key(a:conf_dict, 'ignore_git') && a:conf_dict['ignore_git'] == 1
        let l:cmd += ['--exclude', '.git/']
    endif
    " Apply cached gitignore exclusions from remote
    if has_key(a:conf_dict, '_cached_git_excludes')
        for l:pattern in a:conf_dict['_cached_git_excludes']
            let l:cmd += ['--exclude', l:pattern]
        endfor
    endif

    return l:cmd
endfunction

" ---------- Job handlers ----------

function! JobHandler(job_id, data, event_type) abort
    if a:event_type ==# 'stdout' || a:event_type ==# 'stderr'
        if has_key(getqflist({'id' : s:arsync_qfid}), 'id')
            call setqflist([], 'a', {'id' : s:arsync_qfid, 'lines' : a:data})
        endif
    elseif a:event_type ==# 'exit'
        let s:arsync_running = 0
        if a:data != 0
            call s:SetStatus('error')
            copen
        elseif s:arsync_is_dry_run
            call s:SetStatus('ok')
            echo 'vim-arsync: dry-run completed — see quickfix for changes.'
            copen
        else
            call s:SetStatus('ok')
            if !empty(s:arsync_post_job_cmd)
                call setqflist([], 'a', {'id' : s:arsync_qfid,
                            \ 'lines' : ['', '--- post_sync_cmd ---']})
                call arsync#job#start(s:arsync_post_job_cmd, {
                            \ 'on_stdout': function('s:PostSyncHandler'),
                            \ 'on_stderr': function('s:PostSyncHandler'),
                            \ 'on_exit':   function('s:PostSyncHandler'),
                            \ })
            else
                echo 'vim-arsync: sync completed successfully.'
            endif
        endif
    endif
endfunction

" Handler for the post_sync_cmd SSH job that runs after a successful up-sync.
function! s:PostSyncHandler(job_id, data, event_type) abort
    if a:event_type ==# 'stdout' || a:event_type ==# 'stderr'
        if has_key(getqflist({'id' : s:arsync_qfid}), 'id')
            call setqflist([], 'a', {'id' : s:arsync_qfid, 'lines' : a:data})
        endif
    elseif a:event_type ==# 'exit'
        if a:data != 0
            echo 'vim-arsync: post_sync_cmd failed (exit ' . a:data . ') — see quickfix.'
            copen
        else
            echo 'vim-arsync: sync and post_sync_cmd completed successfully.'
        endif
    endif
endfunction

" Handler for :ARgitStatus SSH query (uses a separate QF list).
function! s:GitStatusHandler(job_id, data, event_type) abort
    if a:event_type ==# 'stdout' || a:event_type ==# 'stderr'
        if has_key(getqflist({'id' : s:git_status_qfid}), 'id')
            call setqflist([], 'a', {'id' : s:git_status_qfid, 'lines' : a:data})
        endif
    elseif a:event_type ==# 'exit'
        copen
        if a:data != 0
            echo 'vim-arsync: git status query failed (exit ' . a:data . ').'
        endif
    endif
endfunction

" ---------- Core functions ----------

" Pretty-print the current configuration and the resolved rsync command.
function! ShowConf() abort
    if !ShouldSync()
        echoerr 'vim-arsync: No .vim-arsync config file found in this directory tree.'
        return
    endif
    let l:conf_dict = LoadConf()
    echo '=== vim-arsync configuration ==='
    for l:item in sort(items(l:conf_dict))
        echo printf('  %-22s = %s', l:item[0], string(l:item[1]))
    endfor
    if has_key(l:conf_dict, 'remote_host')
        echo ''
        echo '=== Resolved rsync command (up) ==='
        let l:cmd = s:BuildRsyncCmd('up', l:conf_dict)
        echo '  ' . join(map(copy(l:cmd), 'shellescape(v:val)'), ' ')
    endif
endfunction

" Main sync entry point. direction: 'up', 'down', 'upDelete', 'downDelete', 'dryRun'.
function! ARsync(direction) abort
    let l:conf_dict = LoadConf()
    if !has_key(l:conf_dict, 'remote_host')
        if empty(findfile('.vim-arsync', '.;'))
            echoerr 'vim-arsync: No .vim-arsync config file found. Aborting...'
        else
            echoerr 'vim-arsync: .vim-arsync is missing required field: remote_host. Aborting...'
        endif
        return
    endif

    if s:arsync_running
        echo 'vim-arsync: sync already in progress, skipping.'
        return
    endif

    " Confirmation prompt before destructive down-syncs when warn_on_down = 1
    if (a:direction ==# 'down' || a:direction ==# 'downDelete')
                \ && has_key(l:conf_dict, 'warn_on_down') && l:conf_dict['warn_on_down'] == 1
        let l:answer = input('vim-arsync: This will overwrite local files. Proceed? (y/N) ')
        echo ''
        if l:answer !~# '^[yY]'
            echo 'vim-arsync: Down-sync cancelled.'
            return
        endif
    endif

    " Auto-fetch gitignore exclusions on first sync if not cached and not opted out
    if !has_key(l:conf_dict, '_cached_git_excludes')
                \ && !(has_key(l:conf_dict, 'no_gitignore') && l:conf_dict['no_gitignore'] == 1)
        echo 'vim-arsync: No cached gitignore excludes. Run :ARsyncRefreshIgnore to fetch from remote.'
    endif

    let l:cmd = s:BuildRsyncCmd(a:direction, l:conf_dict)
    if empty(l:cmd)
        echoerr 'vim-arsync: Unknown sync direction or mode: ' . a:direction
        return
    endif

    " Prepare post-sync SSH command (up-syncs only, not dry-runs)
    let s:arsync_post_job_cmd = []
    if (a:direction ==# 'up' || a:direction ==# 'upDelete')
                \ && has_key(l:conf_dict, 'post_sync_cmd')
                \ && !empty(l:conf_dict['post_sync_cmd'])
        let l:user_at_host = (has_key(l:conf_dict, 'remote_user')
                    \ ? l:conf_dict['remote_user'] . '@' : '') . l:conf_dict['remote_host']
        let s:arsync_post_job_cmd = ['ssh', '-p', string(l:conf_dict['remote_port']),
                    \ l:user_at_host, l:conf_dict['post_sync_cmd']]
    endif

    let s:arsync_is_dry_run = (a:direction ==# 'dryRun')
    let l:dir_symbols = {'up': '↑', 'down': '↓', 'upDelete': '↑!', 'downDelete': '↓!', 'dryRun': '~'}
    let s:arsync_direction_label = get(l:dir_symbols, a:direction, a:direction)
    let s:arsync_target_label = ' ' . (has_key(l:conf_dict, 'remote_user')
                \ ? l:conf_dict['remote_user'] . '@' : '') . l:conf_dict['remote_host']
    let l:title = s:arsync_is_dry_run ? 'vim-arsync [dry-run]' : 'vim-arsync'
    call setqflist([], ' ', {'title' : l:title})
    let s:arsync_qfid = getqflist({'id' : 0}).id
    let s:arsync_running = 1
    call s:SetStatus('syncing')
    call arsync#job#start(l:cmd, {
                \ 'on_stdout': function('JobHandler'),
                \ 'on_stderr': function('JobHandler'),
                \ 'on_exit':   function('JobHandler'),
                \ })
endfunction

" Run rsync with --dry-run --itemize-changes and open quickfix to show results.
function! ARsyncDryRun() abort
    call ARsync('dryRun')
endfunction

" SSH to the remote and display git log + status in the quickfix window.
function! ARgitStatus() abort
    let l:conf_dict = LoadConf()
    if !has_key(l:conf_dict, 'remote_host')
        if empty(findfile('.vim-arsync', '.;'))
            echoerr 'vim-arsync: No .vim-arsync config file found. Aborting...'
        else
            echoerr 'vim-arsync: remote_host not configured. Aborting...'
        endif
        return
    endif

    let l:user_at_host = (has_key(l:conf_dict, 'remote_user')
                \ ? l:conf_dict['remote_user'] . '@' : '') . l:conf_dict['remote_host']
    let l:remote_path = l:conf_dict['remote_path']
    let l:git_base = 'git -C ' . shellescape(l:remote_path)
    let l:remote_shell_cmd = l:git_base . ' log --oneline -5 2>/dev/null'
                \ . '; echo "---"'
                \ . '; ' . l:git_base . ' status --short 2>/dev/null'
    let l:ssh_cmd = ['ssh', '-p', string(l:conf_dict['remote_port']),
                \ l:user_at_host, l:remote_shell_cmd]

    call setqflist([], ' ', {'title' : 'vim-arsync: git @ ' . l:user_at_host . ':' . l:remote_path})
    let s:git_status_qfid = getqflist({'id' : 0}).id
    call arsync#job#start(l:ssh_cmd, {
                \ 'on_stdout': function('s:GitStatusHandler'),
                \ 'on_stderr': function('s:GitStatusHandler'),
                \ 'on_exit':   function('s:GitStatusHandler'),
                \ })
endfunction

" ---------- Gitignore exclusion ----------

" Writes the given excludes list as _cached_git_excludes into the .vim-arsync config file.
" Preserves all other lines; replaces existing _cached_git_excludes or appends.
function! s:WriteGitExcludesToConfig(excludes) abort
    let l:suffix = exists('g:arsync_profile') && !empty(g:arsync_profile)
                \ ? '.' . g:arsync_profile : ''
    let l:config_file = findfile('.vim-arsync' . l:suffix, '.;')
    if empty(l:config_file) && !empty(l:suffix)
        let l:config_file = findfile('.vim-arsync', '.;')
    endif
    if empty(l:config_file)
        echoerr 'vim-arsync: Cannot find .vim-arsync config file to write excludes.'
        return
    endif

    let l:lines = readfile(l:config_file)
    let l:new_line = '_cached_git_excludes ' . json_encode(a:excludes)
    let l:found = 0
    let l:idx = 0
    for l:line in l:lines
        if l:line =~# '^\s*_cached_git_excludes\s'
            let l:lines[l:idx] = l:new_line
            let l:found = 1
            break
        endif
        let l:idx += 1
    endfor
    if !l:found
        call add(l:lines, l:new_line)
    endif
    call writefile(l:lines, l:config_file)
endfunction

" Handler for the git ls-files SSH job used by :ARsyncRefreshIgnore.
function! s:RefreshIgnoreHandler(job_id, data, event_type) abort
    if a:event_type ==# 'stdout'
        let s:git_excludes_output += a:data
    elseif a:event_type ==# 'exit'
        if a:data != 0
            echoerr 'vim-arsync: Failed to fetch git excludes from remote (exit ' . a:data . ').'
            return
        endif
        " Filter empty lines and trailing newline artifacts
        let l:excludes = filter(copy(s:git_excludes_output), '!empty(v:val)')
        call s:WriteGitExcludesToConfig(l:excludes)
        echo 'vim-arsync: Cached ' . len(l:excludes) . ' gitignore exclusion patterns.'
    endif
endfunction

" Fetch the list of git-ignored files/dirs from the remote and cache in .vim-arsync.
function! ARsyncRefreshIgnore() abort
    let l:conf_dict = LoadConf()
    if !has_key(l:conf_dict, 'remote_host')
        echoerr 'vim-arsync: remote_host not configured. Aborting...'
        return
    endif

    let l:user_at_host = (has_key(l:conf_dict, 'remote_user')
                \ ? l:conf_dict['remote_user'] . '@' : '') . l:conf_dict['remote_host']
    let l:remote_path = l:conf_dict['remote_path']
    let l:remote_shell_cmd = 'git -C ' . shellescape(l:remote_path)
                \ . ' ls-files --others --ignored --exclude-standard --directory'
    let l:ssh_cmd = ['ssh', '-p', string(l:conf_dict['remote_port']),
                \ l:user_at_host, l:remote_shell_cmd]

    let s:git_excludes_output = []
    echo 'vim-arsync: Fetching gitignore patterns from remote...'
    call arsync#job#start(l:ssh_cmd, {
                \ 'on_stdout': function('s:RefreshIgnoreHandler'),
                \ 'on_stderr': function('s:RefreshIgnoreHandler'),
                \ 'on_exit':   function('s:RefreshIgnoreHandler'),
                \ })
endfunction

" Sync only the file currently open in the active buffer.
function! ARsyncFile() abort
    let l:conf_dict = LoadConf()
    if !has_key(l:conf_dict, 'remote_host')
        if empty(findfile('.vim-arsync', '.;'))
            echoerr 'vim-arsync: No .vim-arsync config file found. Aborting...'
        else
            echoerr 'vim-arsync: remote_host not configured. Aborting...'
        endif
        return
    endif

    if s:arsync_running
        echo 'vim-arsync: sync already in progress, skipping.'
        return
    endif

    let l:buf_path = expand('%:p')
    if empty(l:buf_path) || !filereadable(l:buf_path)
        echoerr 'vim-arsync: No readable file in current buffer.'
        return
    endif

    let l:local_root  = substitute(l:conf_dict['local_path'], '/\+$', '', '')
    if stridx(l:buf_path, l:local_root) != 0
        echoerr 'vim-arsync: Current file is not under local_path. Aborting...'
        return
    endif

    let l:rel_path    = substitute(l:buf_path[len(l:local_root):], '^/', '', '')
    let l:remote_root = substitute(l:conf_dict['remote_path'], '/\+$', '', '')
    let l:rel_dir     = fnamemodify(l:rel_path, ':h')
    let l:remote_dir  = l:rel_dir ==# '.' ? l:remote_root : l:remote_root . '/' . l:rel_dir

    let l:remote_opts = split(l:conf_dict['remote_options'])
    let l:ssh_cmd     = 'ssh -p ' . l:conf_dict['remote_port']
    let l:user_passwd = has_key(l:conf_dict, 'remote_user')
                \ ? l:conf_dict['remote_user'] . '@' : ''

    let l:dest = l:user_passwd . l:conf_dict['remote_host'] . ':' . l:remote_dir . '/'
    let l:cmd = ['rsync'] + l:remote_opts + ['-e', l:ssh_cmd, l:buf_path, l:dest]

    let s:arsync_post_job_cmd    = []
    let s:arsync_is_dry_run      = 0
    let s:arsync_direction_label = '↑'
    let s:arsync_target_label    = ' ' . fnamemodify(l:buf_path, ':t')
    call setqflist([], ' ', {'title' : 'vim-arsync [file: ' . fnamemodify(l:buf_path, ':t') . ']'})
    let s:arsync_qfid = getqflist({'id' : 0}).id
    let s:arsync_running = 1
    call s:SetStatus('syncing')
    call arsync#job#start(l:cmd, {
                \ 'on_stdout': function('JobHandler'),
                \ 'on_stderr': function('JobHandler'),
                \ 'on_exit':   function('JobHandler'),
                \ })
endfunction

" Sync only the directory containing the file open in the active buffer.
function! ARsyncDir() abort
    let l:conf_dict = LoadConf()
    if !has_key(l:conf_dict, 'remote_host')
        if empty(findfile('.vim-arsync', '.;'))
            echoerr 'vim-arsync: No .vim-arsync config file found. Aborting...'
        else
            echoerr 'vim-arsync: remote_host not configured. Aborting...'
        endif
        return
    endif

    if s:arsync_running
        echo 'vim-arsync: sync already in progress, skipping.'
        return
    endif

    let l:buf_dir = expand('%:p:h')
    if empty(l:buf_dir)
        echoerr 'vim-arsync: Cannot determine current buffer directory.'
        return
    endif

    let l:local_root = substitute(l:conf_dict['local_path'], '/\+$', '', '')
    if stridx(l:buf_dir, l:local_root) != 0
        echoerr 'vim-arsync: Current directory is not under local_path. Aborting...'
        return
    endif

    let l:rel_dir     = substitute(l:buf_dir[len(l:local_root):], '^/', '', '')
    let l:remote_root = substitute(l:conf_dict['remote_path'], '/\+$', '', '')
    let l:remote_dir  = empty(l:rel_dir) ? l:remote_root : l:remote_root . '/' . l:rel_dir

    let l:remote_opts = split(l:conf_dict['remote_options'])
    let l:ssh_cmd     = 'ssh -p ' . l:conf_dict['remote_port']
    let l:user_passwd = has_key(l:conf_dict, 'remote_user')
                \ ? l:conf_dict['remote_user'] . '@' : ''

    let l:dest = l:user_passwd . l:conf_dict['remote_host'] . ':' . l:remote_dir . '/'
    let l:cmd = ['rsync'] + l:remote_opts + ['-e', l:ssh_cmd, l:buf_dir . '/', l:dest]

    let s:arsync_post_job_cmd    = []
    let s:arsync_is_dry_run      = 0
    let s:arsync_direction_label = '↑'
    let s:arsync_target_label    = ' ' . fnamemodify(l:buf_dir, ':t') . '/'
    call setqflist([], ' ', {'title' : 'vim-arsync [dir: ' . fnamemodify(l:buf_dir, ':t') . ']'})
    let s:arsync_qfid = getqflist({'id' : 0}).id
    let s:arsync_running = 1
    call s:SetStatus('syncing')
    call arsync#job#start(l:cmd, {
                \ 'on_stdout': function('JobHandler'),
                \ 'on_stderr': function('JobHandler'),
                \ 'on_exit':   function('JobHandler'),
                \ })
endfunction

" Switch the active sync profile. Pass '' to revert to the default .vim-arsync.
function! ARsyncProfile(name) abort
    if empty(a:name)
        let g:arsync_profile = ''
        echo 'vim-arsync: Using default profile (.vim-arsync)'
    else
        if empty(findfile('.vim-arsync.' . a:name, '.;'))
            echoerr 'vim-arsync: Profile file .vim-arsync.' . a:name . ' not found in this directory tree.'
            return
        endif
        let g:arsync_profile = a:name
        echo 'vim-arsync: Switched to profile "' . a:name . '" (.vim-arsync.' . a:name . ')'
    endif
    call AutoSync()
endfunction

" Debounced wrapper called by the BufWritePost autocmd when debounce_ms is set.
function! s:DebouncedSync() abort
    if s:arsync_debounce_timer != -1
        call timer_stop(s:arsync_debounce_timer)
    endif
    let s:arsync_debounce_timer = timer_start(g:arsync_debounce_ms,
                \ { -> execute("call ARsync('up')", '') })
endfunction

" Register (or clear) auto-sync autocmds for the current project.
" Re-evaluated on VimEnter and DirChanged.
function! AutoSync() abort
    " Always reset the auto-sync group first to prevent duplicate autocmds
    " when AutoSync() is called multiple times (VimEnter, DirChanged, etc.)
    augroup vimarsync_auto
        autocmd!
    augroup END

    if !ShouldSync()
        return
    endif

    let l:conf_dict = LoadConf()
    if has_key(l:conf_dict, 'auto_sync_up') && l:conf_dict['auto_sync_up'] == 1
        augroup vimarsync_auto
            if has_key(l:conf_dict, 'debounce_ms') && l:conf_dict['debounce_ms'] > 0
                " debounce_ms: coalesce rapid saves — reset the timer on each write
                let g:arsync_debounce_ms = l:conf_dict['debounce_ms']
                autocmd BufWritePost,FileWritePost * call s:DebouncedSync()
            elseif has_key(l:conf_dict, 'sleep_before_sync') && l:conf_dict['sleep_before_sync'] > 0
                let g:arsync_sleep_time = l:conf_dict['sleep_before_sync'] * 1000
                autocmd BufWritePost,FileWritePost * call timer_start(g:arsync_sleep_time, { -> execute("call ARsync('up')", "")})
            else
                autocmd BufWritePost,FileWritePost * call ARsync('up')
            endif
        augroup END
    endif
endfunction

if !executable('rsync')
    echoerr 'vim-arsync: rsync is required but not found in PATH.'
    finish
endif

command! ARsyncUp          call ARsync('up')
command! ARsyncUpDelete    call ARsync('upDelete')
command! ARsyncDown        call ARsync('down')
command! ARsyncDownDelete  call ARsync('downDelete')
command! ARsyncDryRun      call ARsyncDryRun()
command! ARsyncFile        call ARsyncFile()
command! ARsyncDir         call ARsyncDir()
command! ARgitStatus       call ARgitStatus()
command! ARshowConf        call ShowConf()
command! ARsyncRefreshIgnore call ARsyncRefreshIgnore()
command! -nargs=1 ARsyncProfile call ARsyncProfile(<q-args>)

augroup vimarsync
    autocmd!
    autocmd VimEnter  * call AutoSync()
    autocmd DirChanged * call AutoSync()
augroup END
