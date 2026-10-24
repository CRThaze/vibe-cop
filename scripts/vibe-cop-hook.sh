#!/usr/bin/env bash
#
# vibe-cop enforcement hook. Registered for PreToolUse (Write|Edit|NotebookEdit|
# Bash), UserPromptSubmit, and SessionStart. When advisor mode is ON for the
# session it denies file writes to protected paths and version-control/forge
# mutations, and injects a standing reminder on each prompt. When OFF it is a
# no-op, except that SessionStart turns it on when the .vrc says "default: on".

state_dir="${TMPDIR:-/tmp}"

# Resolve the .vrc scratch-dir directive, the advisor's own space for notes,
# memories, and scratch files: relative to the workspace root, ~ for home.
# Prints nothing when unset, and fails when the dir would hold the workspace or
# its config, since every file in it is writable. Call after load_vrc.
scratch_path()
{
    local dir="$vrc_scratch_dir"
    local real
    local held

    # shellcheck disable=SC2088  # the ~ patterns match a literal ~ from the .vrc
    case "$dir" in
        '')
            return 0
            ;;
        '~'|'~/'*)
            dir="${HOME}${dir#\~}"
            ;;
        /*)
            ;;
        *)
            dir="$vrc_root/$dir"
            ;;
    esac

    real="$(realpath -m -- "$dir")"
    for held in "$(realpath -m -- "$vrc_root")/" "$(realpath -m -- "$vrc_file")"
    do
        case "$held" in
            "${real%/}"/*)
                return 1
                ;;
            *)
                ;;
        esac
    done
    realpath -ms -- "$dir"
}

# Return 0 if $1 lies in a Claude Code auto-memory dir,
# <config dir>/projects/<project>/memory/. Any project's counts, since the
# <project> key follows the git repo and is not worth re-deriving here.
# ponytail: an autoMemoryDirectory setting is not covered; read the settings
# files for it if one is ever used.
in_memory_dir()
{
    local rel

    rel="$(rel_inside "$(realpath -m -- "$1")" "$(realpath -m -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects")")"
    case "${rel#*/}" in
        memory/?*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

emit_deny()
{
    local reason="$1"
    jq -n --arg r "$reason" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
        }
    }'
    exit 0
}

emit_reminder()
{
    local files="Do NOT create, modify, or delete tracked or source files (only /tmp scratch and gitignored build artifacts are writable)."
    local pats

    if [ -n "$vrc_file" ] && [ "$vrc_mode" != "none" ]
    then
        pats="$(vrc_pattern_list)"
        case "$vrc_mode" in
            allowlist)
                files="Workspace file edits follow $vrc_file (allowlist): you MAY Write/Edit only files matching its gitignore-style patterns ($pats); every other workspace file is read-only."
                ;;
            blocklist)
                files="Workspace file edits follow $vrc_file (blocklist): you MAY Write/Edit any workspace file EXCEPT those matching its gitignore-style patterns ($pats)."
                ;;
            *)
                files="$vrc_file is malformed (it needs a 'mode: allowlist' or 'mode: blocklist' line), so all workspace file edits are blocked; tell the user."
                ;;
        esac
        files="$files Never edit the config or .git/. Outside the workspace only /tmp scratch and gitignored build artifacts are writable."
    fi
    if [ -n "$scratch_dir" ]
    then
        files="$files You MAY keep notes and scratch files in $scratch_dir, wherever it sits."
    fi
    if [ "$vrc_memory" = "off" ]
    then
        files="$files Do NOT write auto memory: $vrc_file turns it off."
    else
        files="$files Saving auto memory to your memory directory is fine."
    fi

    jq -n --arg files "$files" '{
        hookSpecificOutput: {
            hookEventName: "UserPromptSubmit",
            additionalContext: ("[vibe-cop mode ON. You guide, and teach when needed; the user writes the code. In chat, say where to change, what, and why, with a short example or fix when it helps. Do NOT write the change for the user: no diffs or patches, no whole functions or files to paste in, no edited copies of project files. " + $files + " Do NOT run version-control writes (commit/add/push/pull/merge/rebase/reset/checkout/branch/tag/stash). Do NOT create or modify anything on a forge (gh/glab). Read-only git and gh (diff/log/show/status/view/list) are fine.]")
        }
    }'
    exit 0
}

# Print $1 relative to directory $2, or nothing when $1 is not inside $2.
rel_inside()
{
    case "$1" in
        "${2%/}"/*)
            printf '%s' "${1#"${2%/}"/}"
            ;;
        *)
            ;;
    esac
}

# Locate the workspace config. Sets vrc_root (the git worktree top, else the
# project dir, kept unresolved so paths through symlinks still sit under it),
# vrc_file (.vrc at the root, else vrc in the git common dir so linked worktrees
# share .git/vrc; empty when neither exists), vrc_mode (allowlist|blocklist,
# none for a file of directives only, empty when the mode directive is missing
# or bad), vrc_scratch_dir (the scratch-dir directive, empty when unset),
# vrc_default (on when the file says "default: on"), vrc_memory (off when it
# says "memory: off"), and vrc_patterns (the file minus its directive lines).
load_vrc()
{
    local proj="${CLAUDE_PROJECT_DIR:-$1}"
    local -a git_info

    vrc_root=""
    vrc_file=""
    vrc_mode=""
    vrc_scratch_dir=""
    vrc_default=""
    vrc_memory=""
    vrc_patterns=""
    [ -n "$proj" ] || return 0

    proj="$(realpath -ms -- "$proj")"
    vrc_root="$proj"
    mapfile -t git_info < <(git -C "$proj" rev-parse --show-prefix --path-format=absolute --git-common-dir 2>/dev/null)
    if [ "${#git_info[@]}" -eq 2 ]
    then
        vrc_root="${proj%/"${git_info[0]%/}"}"
    fi

    if [ -f "$vrc_root/.vrc" ]
    then
        vrc_file="$vrc_root/.vrc"
    elif [ "${#git_info[@]}" -eq 2 ] && [ -f "${git_info[1]}/vrc" ]
    then
        vrc_file="${git_info[1]}/vrc"
    else
        return 0
    fi

    vrc_mode="$(sed -nE 's/^mode:[[:space:]]*(allowlist|blocklist)[[:space:]]*$/\1/p' "$vrc_file" | head -n1)"
    vrc_scratch_dir="$(sed -nE 's/^scratch-dir:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$vrc_file" | head -n1)"
    vrc_default="$(sed -nE 's/^default:[[:space:]]*(on)[[:space:]]*$/\1/p' "$vrc_file" | head -n1)"
    vrc_memory="$(sed -nE 's/^memory:[[:space:]]*(off)[[:space:]]*$/\1/p' "$vrc_file" | head -n1)"
    vrc_patterns="$(grep -vE '^(mode|scratch-dir|default|memory):' "$vrc_file")"

    # A file of directives alone sets no file policy, so the default rule holds.
    # A bad mode line, or patterns without one, stays malformed and blocks edits.
    if ! grep -qE '^mode:' "$vrc_file" && ! grep -qvE '^[[:space:]]*(#|$)' <<<"$vrc_patterns"
    then
        vrc_mode="none"
    fi
}

# Print the config's patterns comma-separated, or "none".
vrc_pattern_list()
{
    local pats
    local -a lines

    mapfile -t lines < <(grep -vE '^[[:space:]]*(#|$)' <<<"$vrc_patterns")
    printf -v pats '%s, ' "${lines[@]}"
    pats="${pats%, }"
    printf '%s' "${pats:-none}"
}

# Run `git check-ignore --no-index "$@"` with vrc_patterns as the only rules:
# exits 0 if a path matched (printing it), 1 if none did, 128 if git failed. The
# work tree is an empty scratch dir, so the real tree's .gitignore files stay out
# and every leading path component counts as a directory: a listed directory
# covers everything beneath it, through symlinked subdirectories too.
vrc_check_ignore()
{
    local scratch
    local rc

    scratch="$(mktemp -d)" || return 128
    printf '%s\n' "$vrc_patterns" > "$scratch/patterns"
    git init -q --template= "$scratch/w" 2>/dev/null
    git -C "$scratch/w" -c core.excludesFile="$scratch/patterns" -c core.ignoreCase=false \
        check-ignore --no-index "$@" 2>/dev/null
    rc=$?
    rm -rf "$scratch"
    return "$rc"
}

# Print the existing workspace paths vrc_patterns match, sorted, with a matched
# directory collapsed to "dir/". git lists the real tree but treats a symlink as
# a file and never descends it, so symlinked directories are probed separately
# as directories.
vrc_list()
{
    local scratch

    scratch="$(mktemp -d)" || return 1
    printf '%s\n' "$vrc_patterns" > "$scratch/patterns"
    git init -q --bare --template= "$scratch/g" 2>/dev/null
    {
        git --git-dir="$scratch/g" --work-tree="$vrc_root" -C "$vrc_root" \
            ls-files --others --ignored --directory --exclude-from="$scratch/patterns" 2>/dev/null
        find "$vrc_root" -path "$vrc_root/.git" -prune -o -type l -xtype d -printf '%P/\n' 2>/dev/null |
            vrc_check_ignore --stdin
    } | LC_ALL=C sort -u |
        awk '{ for (d in shown) if (index($0, d) == 1) next; print; if (/\/$/) shown[$0] }' |
        grep -vxF .vrc
    rm -rf "$scratch"
}

# Decide a write target that lies inside the workspace by its path as given or
# by its symlink-resolved path. The config and .git/ are never writable; with a
# config, its allowlist or blocklist decides. Targets outside the workspace
# return undecided and fall through to the default rule.
check_vrc_policy()
{
    local path="$1"
    local rel
    local rc
    local -a rels=()

    [ -n "$vrc_root" ] || return 0

    for rel in "$(rel_inside "$(realpath -ms -- "$path")" "$vrc_root")" \
               "$(rel_inside "$(realpath -m -- "$path")" "$(realpath -m -- "$vrc_root")")"
    do
        case "$rel" in
            '')
                ;;
            .vrc|.git|.git/*)
                emit_deny "vibe-cop (advisor) mode is ON: \"$path\" is the vibe-cop config or inside .git/, which are never writable in this mode. Tell the user what to change instead."
                ;;
            *)
                rels+=("$rel")
                ;;
        esac
    done
    [ "${#rels[@]}" -gt 0 ] || return 0
    [ -n "$vrc_file" ] || return 0
    [ "$vrc_mode" != "none" ] || return 0

    if [ -z "$vrc_mode" ]
    then
        emit_deny "vibe-cop (advisor) mode is ON: $vrc_file is malformed (it needs a 'mode: allowlist' or 'mode: blocklist' line), so workspace edits are blocked. Ask the user to fix it."
    fi

    vrc_check_ignore -- "${rels[@]}" >/dev/null
    rc=$?
    case "$vrc_mode:$rc" in
        allowlist:0|blocklist:1)
            exit 0
            ;;
        allowlist:1)
            emit_deny "vibe-cop (advisor) mode is ON: \"$path\" is not allowlisted in $vrc_file, so it is read-only. $advise"
            ;;
        blocklist:0)
            emit_deny "vibe-cop (advisor) mode is ON: \"$path\" is blocklisted in $vrc_file, so it is read-only. $advise"
            ;;
        *)
            emit_deny "vibe-cop (advisor) mode is ON: could not evaluate $vrc_file for \"$path\", so the write is blocked. $advise"
            ;;
    esac
}

# Emit the argv of a shell segment with leading env-assignments and benign
# command prefixes (sudo, env, ...) removed, one word per line.
clean_words()
{
    local -a words
    local i=0
    local w
    read -ra words <<<"$1"
    while [ "$i" -lt "${#words[@]}" ]
    do
        w="${words[$i]}"
        if [[ "$w" == *=* && "$w" != -* && "${w%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
        then
            i=$((i + 1))
            continue
        fi
        case "$w" in
            sudo|command|env|nohup|nice|time|builtin|exec|stdbuf|setsid)
                i=$((i + 1))
                continue
                ;;
            *)
                break
                ;;
        esac
    done
    printf '%s\n' "${words[@]:$i}"
}

# Given the tokens after "git", skip git's global options and echo the
# subcommand (empty if there is none, e.g. bare `git` or `git --version`).
git_subcommand()
{
    while [ "$#" -gt 0 ]
    do
        case "$1" in
            -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env)
                shift 2 2>/dev/null || shift
                continue
                ;;
            --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--attr-source=*|--config-env=*)
                shift
                continue
                ;;
            -p|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--no-lazy-fetch)
                shift
                continue
                ;;
            -*)
                shift
                continue
                ;;
            *)
                printf '%s' "$1"
                return 0
                ;;
        esac
    done
    return 0
}

# Return 0 (is a write) if `gh api` / `glab api` args carry a write method or a
# body field; return 1 for a plain GET.
forge_api_writes()
{
    local expect_method=""
    local a
    for a in "$@"
    do
        case "$a" in
            -f|-F|--field|--raw-field|--input)
                return 0
                ;;
            -X|--method)
                expect_method="yes"
                continue
                ;;
            --method=*|-X=*)
                case "${a#*=}" in
                    GET|get|HEAD|head)
                        ;;
                    *)
                        return 0
                        ;;
                esac
                ;;
            *)
                if [ "$expect_method" = "yes" ]
                then
                    case "$a" in
                        GET|get|HEAD|head)
                            ;;
                        *)
                            return 0
                            ;;
                    esac
                    expect_method=""
                fi
                ;;
        esac
    done
    return 1
}

# Scan a Bash command for blocked VCS or forge operations. Prints a deny reason
# on the first violation found; prints nothing when the command is allowed.
bash_violation()
{
    local cmd="$1"
    local seg
    local -a cw
    local tool
    local sub
    local verb

    local git_read='^(status|diff|log|show|blame|ls-files|ls-tree|cat-file|rev-parse|rev-list|describe|shortlog|reflog|grep|for-each-ref|merge-base|name-rev|check-ignore|check-attr|count-objects|whatchanged|version|help)$'
    local vcs_write='^(commit|ci|add|rm|remove|mv|move|push|pull|fetch|clone|merge|rebase|reset|revert|checkout|switch|restore|update|up|import|export|tag|branch|init|apply|patch|stash|cherry-pick|am)$'
    local forge_write='^(create|delete|edit|merge|close|comment|review|reopen|ready|draft|upload|download|clone|fork|run|rerun|cancel|set|unset|add|remove|rename|archive|unarchive|restore|sync|transfer|pin|unpin|lock|unlock|login|logout|refresh|install|uninstall|upgrade|enable|disable|import|approve|new|revoke|regenerate|setup-git)$'

    while IFS= read -r seg
    do
        seg="${seg#"${seg%%[![:space:]]*}"}"
        [ -n "$seg" ] || continue
        mapfile -t cw < <(clean_words "$seg")
        [ "${#cw[@]}" -gt 0 ] || continue
        tool="$(basename -- "${cw[0]}" 2>/dev/null || printf '%s' "${cw[0]}")"

        case "$tool" in
            git)
                sub="$(git_subcommand "${cw[@]:1}")"
                if [ -n "$sub" ] && ! grep -qiE "$git_read" <<<"$sub"
                then
                    printf 'version-control write blocked (git %s). Only read-only git (status/diff/log/show/blame/rev-parse...) is allowed. Describe the git steps for the user to run.' "$sub"
                    return 0
                fi
                ;;
            hg|svn|bzr|jj)
                verb="${cw[1]:-}"
                if [ -n "$verb" ] && grep -qiE "$vcs_write" <<<"$verb"
                then
                    printf 'version-control write blocked (%s %s). Advise the user on the steps instead.' "$tool" "$verb"
                    return 0
                fi
                ;;
            gh|glab)
                if [ "${cw[1]:-}" = "api" ]
                then
                    if forge_api_writes "${cw[@]:2}"
                    then
                        printf 'forge write blocked (%s api with a write method or body field). Only read-only GET queries are allowed.' "$tool"
                        return 0
                    fi
                else
                    verb="${cw[2]:-}"
                    if [ -n "$verb" ] && grep -qiE "$forge_write" <<<"$verb"
                    then
                        printf 'forge write blocked (%s %s %s ...). Creating or changing anything on a forge is not allowed. Only read-only queries (view/list/status/checks) are allowed. Tell the user the exact command to run.' "$tool" "${cw[1]:-}" "$verb"
                        return 0
                    fi
                fi
                ;;
            *)
                ;;
        esac
    done < <(printf '%s\n' "$cmd" | sed -E 's/\|\||&&|;|\||&/\n/g')

    return 0
}

# Return 0 if a write would author a patch: a .patch/.diff target, or content
# carrying a unified-diff hunk header.
is_patch()
{
    case "$1" in
        *.patch|*.diff)
            return 0
            ;;
        *)
            ;;
    esac
    grep -qE '^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@' <<<"$2"
}

check_write_path()
{
    local path="$1"
    local cwd="$2"
    local content="$3"
    local tmp="${TMPDIR:-/tmp}"
    local own_target=""
    local anchor
    local repo

    if [ -z "$path" ]
    then
        emit_deny "vibe-cop mode is ON: the write target could not be determined, so it is blocked. $advise"
    fi

    case "$path" in
        /*)
            ;;
        *)
            path="${cwd%/}/$path"
            ;;
    esac

    # The scratch dir and auto memory are the advisor's own space, even inside
    # .git/ or a read-only part of the workspace, so they skip the workspace
    # policy. Edits that policy allows are decided inside it.
    if [ -n "$scratch_dir" ] && [ -n "$(rel_inside "$(realpath -m -- "$path")" "$(realpath -m -- "$scratch_dir")")" ]
    then
        own_target="yes"
    elif [ "$vrc_memory" != "off" ] && in_memory_dir "$path"
    then
        own_target="yes"
    else
        check_vrc_policy "$path"
    fi

    # Anywhere else, a patch is the change written for the user.
    if is_patch "$path" "$content"
    then
        emit_deny "vibe-cop (advisor) mode is ON: \"$path\" would hold a patch or diff. $advise"
    fi

    if [ -n "$own_target" ]
    then
        exit 0
    fi

    case "$path" in
        "${tmp%/}"/*|/tmp/*)
            exit 0
            ;;
    esac

    # Anchor git queries at the nearest existing ancestor so writes to a
    # not-yet-created build dir still classify correctly.
    anchor="$path"
    while [ -n "$anchor" ] && [ "$anchor" != "/" ] && [ ! -d "$anchor" ]
    do
        anchor="$(dirname "$anchor")"
    done

    repo="$(git -C "$anchor" rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$repo" ] && git -C "$repo" check-ignore -q -- "$path"
    then
        exit 0
    fi

    emit_deny "vibe-cop (advisor) mode is ON: I will not create or modify \"$path\". Only verification scratch under ${tmp}${scratch_dir:+, the scratch dir $scratch_dir,} and gitignored build artifacts are writable. $advise"
}

######################
### Main dispatch  ###
######################

# The toggle script sources this file for the vrc helpers only.
if [ "${BASH_SOURCE[0]}" != "$0" ]
then
    return 0
fi

input="$(cat)"

event="$(jq -r '.hook_event_name // empty' <<<"$input")"

# "default: on" in the workspace config turns the mode on for every new,
# resumed, or cleared session. Compaction is skipped so a /vibe-cop off holds
# for the rest of the session. SessionStart stdout lands in Claude's context.
if [ "$event" = "SessionStart" ]
then
    cwd="$(jq -r '.cwd // empty' <<<"$input")"
    load_vrc "$cwd"
    if [ "$vrc_default" = "on" ] && [ "$(jq -r '.source // empty' <<<"$input")" != "compact" ]
    then
        printf 'The "default: on" line in %s turned vibe-cop mode on for this session; the user can leave it with /vibe-cop off.\n\n' "$vrc_file"
        CLAUDE_CODE_SESSION_ID="$(jq -r '.session_id // empty' <<<"$input")" \
            CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$cwd}" "$(dirname "$0")/vibe-cop-toggle.sh" on
    fi
    exit 0
fi

# Auto-approve our own mode-toggle script so /vibe-cop never hits a permission
# prompt. Runs before the mode gate and in both directions (on and off). Bash
# commands do not get CLAUDE_PROJECT_DIR, so hand the toggle the same root this
# hook resolves the config from; otherwise status run from a subdirectory of a
# non-git workspace would miss the .vrc the hook enforces.
if [ "$event" = "PreToolUse" ] && [ "$(jq -r '.tool_name // empty' <<<"$input")" = "Bash" ]
then
    toggle_cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
    case "$toggle_cmd" in
        *vibe-cop-toggle.sh*)
            jq --arg proj "${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // empty' <<<"$input")}" '{
                hookSpecificOutput: {
                    hookEventName: "PreToolUse",
                    permissionDecision: "allow",
                    permissionDecisionReason: "vibe-cop mode toggle (bundled script)",
                    updatedInput: (.tool_input | .command = "export CLAUDE_PROJECT_DIR=\($proj | @sh); \(.command)")
                }
            }' <<<"$input"
            exit 0
            ;;
        *)
            ;;
    esac
fi

sid_payload="$(jq -r '.session_id // empty' <<<"$input")"

mode_on=""
for sid in "$sid_payload" "${CLAUDE_CODE_SESSION_ID:-}"
do
    if [ -n "$sid" ] && [ -f "${state_dir%/}/vibe-cop-${sid}.on" ]
    then
        mode_on="yes"
        break
    fi
done

if [ -z "$mode_on" ]
then
    exit 0
fi

cwd="$(jq -r '.cwd // empty' <<<"$input")"
load_vrc "$cwd"
scratch_dir="$(scratch_path)"
advise="Guide the user in chat instead: where, what, and why, with a short example if it helps. The user writes the change."

case "$event" in
    UserPromptSubmit)
        emit_reminder
        ;;
    PreToolUse)
        tool="$(jq -r '.tool_name // empty' <<<"$input")"
        case "$tool" in
            Write|Edit|NotebookEdit)
                path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")"
                content="$(jq -r '.tool_input.content // .tool_input.new_string // .tool_input.new_source // empty' <<<"$input")"
                check_write_path "$path" "$cwd" "$content"
                ;;
            Bash)
                cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
                reason="$(bash_violation "$cmd")"
                if [ -n "$reason" ]
                then
                    emit_deny "vibe-cop (advisor) mode is ON: $reason"
                fi
                ;;
            *)
                ;;
        esac
        ;;
    *)
        ;;
esac

exit 0
