#!/usr/bin/env bash
#
# Runnable check for the vibe-cop enforcement hook. Builds a throwaway git repo,
# turns the mode on for a test session id, and asserts deny/allow decisions for a
# spread of Write/Edit and Bash cases. Exits non-zero if any assertion fails.

here="$(cd "$(dirname "$0")" && pwd)"
hook="${here}/vibe-cop-hook.sh"

state_dir="${TMPDIR:-/tmp}"
sid="vibe-cop-selftest-$$"
sid_off="vibe-cop-selftest-off-$$"
sid_start="vibe-cop-selftest-start-$$"
state_file="${state_dir%/}/vibe-cop-${sid}.on"
patch=$'--- a/src/app.py\n+++ b/src/app.py\n@@ -1,2 +1,2 @@\n-old\n+new\n'

# Locate the throwaway repo outside the temp dir, since writes under /tmp are
# intentionally allowed as scratch and would mask the tracked-file assertion.
work="$(mktemp -d "${HOME}/.vibe-cop-selftest.XXXXXX")"
git -C "$work" init -q
printf 'build/\n' > "$work/.gitignore"
nogit="$(mktemp -d "${HOME}/.vibe-cop-selftest-nogit.XXXXXX")"

cleanup()
{
    rm -f "$state_file" "${state_dir%/}/vibe-cop-${sid_start}.on"
    rm -rf "$work" "$nogit"
}
trap cleanup EXIT

pass=0
fail=0

bash_payload()
{
    jq -n --arg s "$1" --arg cmd "$2" \
        '{hook_event_name:"PreToolUse", session_id:$s, tool_name:"Bash", tool_input:{command:$cmd}, cwd:"/"}'
}

write_payload()
{
    jq -n --arg s "$1" --arg tool "$2" --arg p "$3" --arg c "$4" --arg body "${5:-}" \
        '{hook_event_name:"PreToolUse", session_id:$s, tool_name:$tool, tool_input:{file_path:$p, content:$body}, cwd:$c}'
}

decision()
{
    local session="$1"
    local json="$2"
    local out
    out="$(CLAUDE_CODE_SESSION_ID="$session" CLAUDE_PROJECT_DIR="$work" bash "$hook" <<<"$json")"
    if grep -q '"permissionDecision": *"deny"' <<<"$out"
    then
        printf 'deny'
    else
        printf 'allow'
    fi
}

check()
{
    local want="$1"
    local desc="$2"
    local got="$3"
    if [ "$got" = "$want" ]
    then
        printf 'ok    %-5s %s\n' "$got" "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL  want=%s got=%s  %s\n' "$want" "$got" "$desc"
        fail=$((fail + 1))
    fi
}

# Enable the mode for the test session.
touch "$state_file"

##############################
### Mode ON: Bash commands ###
##############################

check deny "git commit blocked"                 "$(decision "$sid" "$(bash_payload "$sid" 'git commit -m x')")"
check allow "git diff allowed"                   "$(decision "$sid" "$(bash_payload "$sid" 'git diff')")"
check deny "git push blocked"                    "$(decision "$sid" "$(bash_payload "$sid" 'git push origin main')")"
check allow "git log allowed"                    "$(decision "$sid" "$(bash_payload "$sid" 'git log --oneline -5')")"
check allow "git -C status allowed"              "$(decision "$sid" "$(bash_payload "$sid" 'git -C /some/repo status')")"
check deny "git -C commit blocked"               "$(decision "$sid" "$(bash_payload "$sid" 'git -C /some/repo commit -m y')")"
check deny "chained git add+commit blocked"      "$(decision "$sid" "$(bash_payload "$sid" 'git add -A && git commit -m z')")"
check allow "chained echo+git status allowed"    "$(decision "$sid" "$(bash_payload "$sid" 'echo hi && git status')")"
check deny "gh pr create blocked"                "$(decision "$sid" "$(bash_payload "$sid" 'gh pr create --fill')")"
check allow "gh pr view allowed"                 "$(decision "$sid" "$(bash_payload "$sid" 'gh pr view 12')")"
check deny "gh api POST blocked"                 "$(decision "$sid" "$(bash_payload "$sid" 'gh api -X POST repos/o/r/issues')")"
check allow "gh api GET allowed"                 "$(decision "$sid" "$(bash_payload "$sid" 'gh api repos/o/r')")"
check deny "gh repo delete blocked"              "$(decision "$sid" "$(bash_payload "$sid" 'gh repo delete o/r --yes')")"
check allow "make build allowed"                 "$(decision "$sid" "$(bash_payload "$sid" 'make build')")"
check deny "svn commit blocked"                  "$(decision "$sid" "$(bash_payload "$sid" 'svn commit -m x')")"
check allow "toggle script auto-approved (ON)"   "$(decision "$sid" "$(bash_payload "$sid" '"/x/plugin/scripts/vibe-cop-toggle.sh" off')")"
check allow "toggle script auto-approved (OFF)"  "$(decision "$sid_off" "$(bash_payload "$sid_off" '"/x/plugin/scripts/vibe-cop-toggle.sh" on')")"

################################
### Mode ON: file write tool ###
################################

check deny "edit tracked/source file blocked"    "$(decision "$sid" "$(write_payload "$sid" Edit "$work/src/app.py" "$work")")"
check allow "write gitignored artifact allowed"  "$(decision "$sid" "$(write_payload "$sid" Write "$work/build/out.o" "$work")")"
check allow "write /tmp scratch allowed"         "$(decision "$sid" "$(write_payload "$sid" Write "/tmp/vibe-scratch.$$" "$work")")"
check deny "patch content to /tmp blocked"       "$(decision "$sid" "$(write_payload "$sid" Write "/tmp/vibe-scratch.$$" "$work" "$patch")")"
check deny ".patch file to /tmp blocked"         "$(decision "$sid" "$(write_payload "$sid" Write "/tmp/vibe-scratch.$$.patch" "$work" "rename foo")")"
check deny "patch into gitignored artifact"      "$(decision "$sid" "$(write_payload "$sid" Write "$work/build/fix.txt" "$work" "$patch")")"

#################################################
### Mode ON: workspace .vrc / .git/vrc config ###
#################################################

ws()
{
    decision "$1" "$(write_payload "$1" "$2" "$work/$3" "$work")"
}

mkdir -p "$work/docs" "$work/vendor" "$work/secrets" "$work/src"
touch "$work/docs/README.md"
ln -s ../vendor "$work/docs/vendor"
ln -s docs/README.md "$work/README.md"
ln -s secrets "$work/keys"
printf '.vrc\n' >> "$work/.gitignore"

check deny "no config: creating gitignored .vrc blocked" "$(ws "$sid" Write .vrc)"

printf '# docs only\nmode: allowlist\ndocs/\nkeys/\n' > "$work/.vrc"
check allow "allowlist: file in listed dir"        "$(ws "$sid" Edit docs/a.md)"
check allow "allowlist: new file in new subdir"    "$(ws "$sid" Write docs/new/b.md)"
check allow "allowlist: through symlinked subdir"  "$(ws "$sid" Edit docs/vendor/lib.c)"
check allow "allowlist: symlink into listed dir"   "$(ws "$sid" Edit README.md)"
check deny "allowlist: unlisted file"              "$(ws "$sid" Edit src/app.py)"
check deny "allowlist: gitignored but unlisted"    "$(ws "$sid" Write build/out.o)"
check deny "allowlist: config itself"              "$(ws "$sid" Edit .vrc)"
check deny "allowlist: .git internals"             "$(ws "$sid" Edit .git/config)"
check allow "allowlist: /tmp scratch allowed"      "$(decision "$sid" "$(write_payload "$sid" Write "/tmp/vibe-scratch.$$" "$work")")"
check allow "allowlist: ignored when mode OFF"     "$(ws "$sid_off" Edit src/app.py)"
check allow "allowlist: diff text in allowed file" "$(decision "$sid" "$(write_payload "$sid" Write "$work/docs/patching.md" "$work" "$patch")")"

# docs/ collapses its symlinked vendor/ and README.md target; keys/ is a
# symlinked dir that git alone would not list.
status="$(cd "$work" && CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PROJECT_DIR="$work" bash "${here}/vibe-cop-toggle.sh" status)"
check "docs/ keys/" "status lists matching paths" "$(sed -n 's/^  //p' <<<"$status" | paste -sd ' ')"

printf 'mode: blocklist\nsecrets/\n*.lock\n' > "$work/.vrc"
check allow "blocklist: unlisted file"             "$(ws "$sid" Edit src/app.py)"
check deny "blocklist: file in listed dir"         "$(ws "$sid" Edit secrets/key)"
check deny "blocklist: symlink to listed dir"      "$(ws "$sid" Edit keys/key)"
check deny "blocklist: basename at any depth"      "$(ws "$sid" Write src/deep/yarn.lock)"

rm "$work/.vrc"
printf 'mode: allowlist\nsrc/\n' > "$work/.git/vrc"
check allow ".git/vrc: listed file"                "$(ws "$sid" Edit src/app.py)"
check deny ".git/vrc: unlisted file"               "$(ws "$sid" Edit docs/a.md)"
check deny ".git/vrc: config itself"               "$(ws "$sid" Edit .git/vrc)"

prompt_reminder()
{
    CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PROJECT_DIR="$work" bash "$hook" <<<"$(jq -n --arg s "$sid" --arg c "$work" '{hook_event_name:"UserPromptSubmit", session_id:$s, cwd:$c}')"
}

reminder="$(prompt_reminder)"
named="no"
if grep -q 'allowlist.*(src/)' <<<"$reminder"
then
    named="yes"
fi
check yes "reminder names allowlist patterns" "$named"
check 1 "reminder allows short examples" "$(grep -c 'short example or fix' <<<"$reminder")"

printf 'src/\n' > "$work/.git/vrc"
check deny "malformed config blocks edits"         "$(ws "$sid" Edit src/app.py)"
rm "$work/.git/vrc"

###########################################
### Mode ON: .vrc scratch-dir directive ###
###########################################

printf 'scratch-dir: notes\nmode: allowlist\ndocs/\n' > "$work/.vrc"
check allow "scratch-dir: any file in it"          "$(ws "$sid" Write notes/memory.md)"
check allow "scratch-dir: nested file in it"       "$(ws "$sid" Write notes/a/b.txt)"
check deny "scratch-dir: patch in it"              "$(decision "$sid" "$(write_payload "$sid" Write "$work/notes/fix.txt" "$work" "$patch")")"
check deny "scratch-dir: sibling prefix not in it" "$(ws "$sid" Write notes2/x.md)"
check allow "scratch-dir: before mode line valid"  "$(ws "$sid" Edit docs/a.md)"
check 1 "reminder names scratch dir"               "$(grep -cF "$work/notes" <<<"$(prompt_reminder)")"
on_out="$(cd "$work" && CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PROJECT_DIR="$work" bash "${here}/vibe-cop-toggle.sh" on)"
check 1 "on creates the scratch dir"               "$(find "$work" -maxdepth 1 -name notes -type d | wc -l)"
check 1 "directives are not patterns"              "$(grep -cx 'patterns:   docs/' <<<"$on_out")"

printf 'mode: blocklist\nscratch-dir: .git/vibe-cop\n' > "$work/.vrc"
check allow "scratch-dir inside .git/"             "$(ws "$sid" Write .git/vibe-cop/notes.md)"
check deny "rest of .git/ still blocked"           "$(ws "$sid" Write .git/config)"

printf 'mode: allowlist\ndocs/\nscratch-dir: .\n' > "$work/.vrc"
check deny "scratch-dir holding workspace ignored" "$(ws "$sid" Edit src/app.py)"
status="$(cd "$work" && CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PROJECT_DIR="$work" bash "${here}/vibe-cop-toggle.sh" status)"
check 1 "status flags the ignored scratch-dir"     "$(grep -c 'is ignored' <<<"$status")"
rm "$work/.vrc"

printf 'mode: allowlist\ndocs/\nscratch-dir: .git\n' > "$work/.git/vrc"
check deny "scratch-dir holding .git/vrc ignored"  "$(ws "$sid" Edit .git/vrc)"
rm "$work/.git/vrc"

check "$HOME/r" "scratch-dir ~ expands to home" "$(bash -c '. "$1"; vrc_root=/w; vrc_file=/w/.vrc; vrc_scratch_dir="~/r"; scratch_path' _ "$hook")"

############################
### Mode ON: auto memory ###
############################

mem="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-vibe-cop-selftest"
check allow "auto memory writable by default"      "$(decision "$sid" "$(write_payload "$sid" Write "$mem/memory/note.md" "$work")")"
check deny "transcript dir beside memory blocked"  "$(decision "$sid" "$(write_payload "$sid" Write "$mem/session.jsonl" "$work")")"
printf 'memory: off\n' > "$work/.vrc"
check deny "memory: off blocks auto memory"        "$(decision "$sid" "$(write_payload "$sid" Write "$mem/memory/note.md" "$work")")"
check 1 "memory: off named in reminder"            "$(grep -c 'Do NOT write auto memory' <<<"$(prompt_reminder)")"
status="$(cd "$work" && CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PROJECT_DIR="$work" bash "${here}/vibe-cop-toggle.sh" status)"
check 1 "memory: off is a directive"               "$(grep -c 'directives only' <<<"$status")"
rm "$work/.vrc"

# Bash commands lack CLAUDE_PROJECT_DIR, so the hook passes it to the toggle.
# Without it, status from a subdirectory of a non-git workspace misses the .vrc.
mkdir "$nogit/sub"
printf 'mode: blocklist\nsecrets/\n' > "$nogit/.vrc"
rewritten="$(CLAUDE_PROJECT_DIR="$nogit" bash "$hook" <<<"$(bash_payload "$sid" "\"${here}/vibe-cop-toggle.sh\" status")" | jq -r '.hookSpecificOutput.updatedInput.command')"
status="$(cd "$nogit/sub" && env -u CLAUDE_PROJECT_DIR GIT_CEILING_DIRECTORIES="$HOME" CLAUDE_CODE_SESSION_ID="$sid" bash -c "$rewritten")"
check 1 "status from non-git subdir finds root .vrc" "$(grep -c "^vrc config: $nogit/.vrc " <<<"$status")"

##################################
### Session start: default: on ###
##################################

session_start()
{
    CLAUDE_PROJECT_DIR="$work" bash "$hook" <<<"$(jq -n --arg s "$sid_start" --arg c "$work" --arg src "$1" '{hook_event_name:"SessionStart", session_id:$s, cwd:$c, source:$src}')"
}

printf 'mode: allowlist\ndocs/\n' > "$work/.vrc"
check 0 "no default: startup leaves mode OFF"         "$(session_start startup | grep -c 'vibe-cop mode: ON')"
check allow "no default: edits pass"                 "$(ws "$sid_start" Edit src/app.py)"

printf 'default: on\n' > "$work/.vrc"
check 0 "default on: compaction does not turn it on" "$(session_start compact | grep -c 'vibe-cop mode: ON')"
check allow "default on: still OFF after compaction" "$(ws "$sid_start" Edit src/app.py)"
check 1 "default on: startup injects the persona"    "$(session_start startup | grep -cx 'vibe-cop mode: ON')"
check deny "default on: tracked file blocked"        "$(ws "$sid_start" Edit src/app.py)"
check allow "directives only: gitignored artifact"   "$(ws "$sid_start" Write build/out.o)"
check 0 "directives only: reminder not malformed"    "$(grep -c malformed <<<"$(prompt_reminder)")"
status="$(cd "$work" && CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PROJECT_DIR="$work" bash "${here}/vibe-cop-toggle.sh" status)"
check 1 "directives only: status says so"            "$(grep -c 'directives only, no file policy' <<<"$status")"

printf 'default: on\nmode: allowlst\n' > "$work/.vrc"
check deny "misspelled mode still blocks edits"      "$(ws "$sid_start" Write build/out.o)"
rm "$work/.vrc"

######################
### Mode OFF: pass ###
######################

check allow "git commit allowed when OFF"        "$(decision "$sid_off" "$(bash_payload "$sid_off" 'git commit -m x')")"
check allow "edit tracked allowed when OFF"       "$(decision "$sid_off" "$(write_payload "$sid_off" Edit "$work/src/app.py" "$work")")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
