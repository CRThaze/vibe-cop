#!/usr/bin/env bash
#
# Toggle vibe-cop advisor mode for the current session. State is a marker file
# under the temp dir keyed by session id; the enforcement hook reads it.

state_dir="${TMPDIR:-/tmp}"
sid="${CLAUDE_CODE_SESSION_ID:-unknown}"
state_file="${state_dir%/}/vibe-cop-${sid}.on"

action="${1:-}"

# shellcheck source=vibe-cop-hook.sh
. "$(dirname "$0")/vibe-cop-hook.sh"

load_vrc "$PWD"
scratch_dir="$(scratch_path)"

print_scratch()
{
    if [ -n "$scratch_dir" ]
    then
        printf 'scratch dir: %s (writable for notes and scratch files, but not patches)\n' "$scratch_dir"
    elif [ -n "$vrc_scratch_dir" ]
    then
        printf 'scratch dir: "%s" is ignored, since it would hold the workspace or its config\n' "$vrc_scratch_dir"
    fi
}

print_memory()
{
    if [ "$vrc_memory" = "off" ]
    then
        printf 'auto memory: off ("memory: off" in %s), so do not write memory files in this mode\n' "$vrc_file"
    else
        printf 'auto memory: writable, save memories as usual (memory dirs under %s/projects)\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    fi
}

# Report the workspace config and the existing paths its patterns match. The
# list is capped since Claude reads it back.
print_vrc()
{
    local cap=50
    local label
    local rest
    local -a hits

    if [ -z "$vrc_file" ]
    then
        printf 'vrc config: none (in vibe-cop mode only /tmp scratch and gitignored build artifacts are writable)\n'
        return 0
    fi
    case "$vrc_mode" in
        allowlist)
            label="editable (allowlisted)"
            rest="read-only"
            ;;
        blocklist)
            label="read-only (blocklisted)"
            rest="editable"
            ;;
        none)
            printf 'vrc config: %s (directives only, no file policy: in vibe-cop mode only /tmp scratch%s and gitignored build artifacts are writable)\n' "$vrc_file" "${scratch_dir:+, the scratch dir,}"
            return 0
            ;;
        *)
            printf 'vrc config: %s is malformed (it needs a "mode: allowlist" or "mode: blocklist" line), so all workspace edits are blocked\n' "$vrc_file"
            return 0
            ;;
    esac

    printf 'vrc config: %s (%s, applies while vibe-cop mode is ON)\n' "$vrc_file" "$vrc_mode"
    printf 'patterns:   %s\n' "$(vrc_pattern_list)"
    printf '%s, existing paths:\n' "$label"
    mapfile -t hits < <(vrc_list)
    if [ "${#hits[@]}" -eq 0 ]
    then
        printf '  (none yet; new files matching a pattern still count)\n'
    else
        printf '  %s\n' "${hits[@]:0:$cap}"
    fi
    if [ "${#hits[@]}" -gt "$cap" ]
    then
        printf '  ... and %d more\n' "$((${#hits[@]} - cap))"
    fi
    printf 'Everything else under %s is %s. The config and .git/ are never writable.\n' "$vrc_root" "$rest"
}

print_persona()
{
    cat <<TXT
You are now in vibe-cop (advisor) mode. You are the user's guide, and their
teacher when they need one. The user writes the code; you show them what to
change and why. Do not make the changes yourself.

You MAY:
- Read, search, and analyze anything in the project.
- Run read-only and analysis commands: tests, linters, type-checkers, and builds
  that emit only untracked or gitignored artifacts.
- Read version-control history: git diff, log, show, status, blame.
- Read forge data: gh pr view, gh pr list, and similar read-only queries.
- Keep notes and throwaway scripts that test a hypothesis about the code under
  /tmp${scratch_dir:+, or in the scratch dir ${scratch_dir}}.

You MUST NOT:
- Create, modify, or delete any tracked or source file. Apart from auto memory
  (see below), the only writable targets are /tmp scratch${scratch_dir:+, the scratch dir,}
  and gitignored build artifacts.
- Write the change for the user: no diffs or patches, in chat or in files; no
  whole functions or files to paste in; no edited copies of project files in
  scratch.
- Perform any version-control write: commit, add, push, pull, fetch, merge,
  rebase, reset, revert, checkout, switch, restore, branch, tag, or stash.
- Create or modify anything on a forge (GitHub, GitLab): no pr/issue/release/repo
  create, edit, delete, merge, or comment.

If the workspace has a .vrc (or .git/vrc) config, you may directly edit the
workspace files its allowlist or blocklist allows, and guide the user on the
rest. The per-prompt reminder lists its patterns. The config itself and .git/
stay off-limits${scratch_dir:+, apart from the scratch dir}.

Instead, GUIDE in chat. For each change, say where it goes (the file, and the
function, class, or line range), what to change, why (and what goes wrong
without it), and how the user can check that it works.

When it helps, add a short example or fix: a few lines that show the pattern,
API, or corrected expression, for the user to adapt and write into their code.
Keep it to the point being made; a whole function or file ready to paste is
writing the change for them. When the user is new to something, or asks, teach:
explain the idea behind the change and point to docs. Skip the lesson when they
don't need it.

A hook hard-blocks violating tool calls; treat a denial as a cue to go back to
guiding.
TXT
}

case "$action" in
    on)
        # Without these the hook cannot parse tool calls or resolve paths, and
        # it would let every write through.
        if ! command -v jq >/dev/null || ! realpath -m / >/dev/null 2>&1
        then
            printf 'vibe-cop mode: OFF. It needs jq and GNU realpath (coreutils) to enforce the mode; install them and run /vibe-cop on again.\n'
            exit 1
        fi
        touch "$state_file"
        if [ -n "$scratch_dir" ]
        then
            mkdir -p "$scratch_dir"
        fi
        printf 'vibe-cop mode: ON\n\n'
        print_persona
        printf '\n'
        print_vrc
        print_scratch
        print_memory
        ;;
    off)
        rm -f "$state_file"
        printf 'vibe-cop mode: OFF. Normal operation resumed.\n'
        ;;
    status)
        if [ -f "$state_file" ]
        then
            printf 'vibe-cop mode: ON\n'
        else
            printf 'vibe-cop mode: OFF\n'
        fi
        print_vrc
        print_scratch
        print_memory
        ;;
    *)
        printf 'Usage: /vibe-cop on|off|status\n'
        printf '  on      enable advisor mode (Claude guides and teaches; you write the code)\n'
        printf '  off     disable advisor mode\n'
        printf '  status  show the current mode and what the workspace .vrc allows\n'
        ;;
esac
