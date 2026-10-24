# vibe-cop: read-only advisor mode for Claude Code

[![ci](https://github.com/CRThaze/vibe-cop/actions/workflows/ci.yml/badge.svg)](https://github.com/CRThaze/vibe-cop/actions/workflows/ci.yml)

vibe-cop is a Claude Code plugin for the opposite of vibe coding: Claude
reviews and teaches, and you write the code. Turn on **advisor mode** and
Claude works as a read-only code reviewer and coding mentor. It reads and
analyzes your project, then tells you what to change, where, and why, with
short examples where they help, and teaches the idea behind a change when you
need it. Use it to learn a language or a codebase, to get AI code review
without AI-written code, or to keep an agent from editing files, committing,
or pushing.

While the mode is on, Claude does not touch your working tree or write the
change for you elsewhere: no edits to tracked or source files, no diffs,
patches, or whole functions to paste, no version-control writes (`git commit`,
`git push`, ...), and nothing created or changed on a forge (GitHub, GitLab).
Its only writes are `/tmp` scratch, gitignored build artifacts, its own auto
memory, and an optional scratch dir. Unlike plan mode, which ends with Claude
making the changes, advisor mode lasts the whole session.

## Install

```
/plugin marketplace add CRThaze/vibe-cop
/plugin install vibe-cop@crthaze-plugins
```

The plugin ships its own hooks, so no settings changes are needed. The mode
defaults to **off**, so installing it does not affect normal sessions until you
turn it on, or a workspace opts in with `default: on` (see below).

Requires bash, git, `jq`, and GNU `realpath` (coreutils). On macOS, install
`jq` and `coreutils` and put GNU `realpath` first on `PATH`. `/vibe-cop on`
refuses to turn the mode on when either is missing, since the hook cannot
enforce anything without them.

## Usage

```
/vibe-cop on       enable advisor mode for this session
/vibe-cop off      disable it
/vibe-cop status   show the current mode and what the workspace .vrc allows
```

The mode is per session and starts off in each new session, unless the
workspace config says `default: on`.

## Default on

A `default: on` line in the workspace `.vrc` (or `.git/vrc`) turns the mode on
at the start of every new, resumed, or cleared session in that workspace, via a
`SessionStart` hook that does what `/vibe-cop on` does. `/vibe-cop off` still
turns it off, and compaction does not turn it back on. A committed `.vrc` opts
in everyone who has the plugin; `.git/vrc` opts in only your checkout.

The line can stand alone; a config of directives alone sets no file policy, so
the default write rule applies:

```
default: on
```

To make sure collaborators have the plugin, commit a project
`.claude/settings.json` that enables it:

```json
{
  "enabledPlugins": { "vibe-cop@crthaze-plugins": true }
}
```

## What it enforces

Two layers work together:

1. **Advisor persona.** Turning the mode on injects a standing instruction that
   Claude act as an advisor: read and analyze freely, run read-only and build
   commands, and guide you through each change in chat (see below) instead of
   writing it. A short reminder is re-injected on each prompt so the role holds
   over a long session.

2. **Hook guardrail** (`PreToolUse`). A hard backstop that denies the clear-cut
   violations:
   - `Write` / `Edit` / `NotebookEdit` to any path that is not under `/tmp`
     (or `$TMPDIR`), the scratch dir, or an auto-memory dir, and is not
     gitignored. Tracked files, new would-be-source files, and writes in non-git
     projects are blocked; gitignored build artifacts, scratch, and memory are
     allowed. A workspace config can replace this rule inside the workspace (see
     below).
   - `Write` / `Edit` / `NotebookEdit` that would author a patch: a `.patch` or
     `.diff` target, or content containing a unified-diff hunk header. This
     applies everywhere except workspace files a `.vrc` lets Claude edit.
   - `Bash` commands that run a version-control **write** (git commit, add, push,
     pull, fetch, merge, rebase, reset, checkout, branch, tag, stash, ...; also
     `hg`/`svn`/`bzr`/`jj` writes). Read-only git (status, diff, log, show,
     blame, rev-parse, ...) stays allowed so the advisor can review.
   - `Bash` commands that **mutate a forge** (`gh`/`glab` create, edit, delete,
     merge, comment, upload, run, ..., and `gh api` with a write method or body
     field). Read-only queries (view, list, status, checks) stay allowed.

General file creation via Bash (for example `make` producing untracked
artifacts) is left to the advisor persona rather than hard-blocked, so ordinary
builds and test runs keep working.

## Guidance

The point of the mode is that you write the code and Claude guides you. For
each change it says, in chat, where it goes (the file, and the function, class,
or line range), what to change, why, and how to check it. When it helps, it adds
a short example or fix: a few lines that show the pattern, API, or corrected
expression, for you to adapt. It does not hand over diffs, patches, or whole
functions and files to paste. When you are new to something, or ask, it explains
the idea behind the change.

## Scratch dir

Claude can keep notes and throwaway scripts under `/tmp`, which does not
survive a reboot. A `scratch-dir: <dir>` directive in the workspace `.vrc`
gives it a lasting place: every file under the directory is writable, wherever
it is, including inside `.git/` (`scratch-dir: .git/vibe-cop` keeps it out of
version control) or a part of the workspace the config makes read-only. The
directory is relative to the workspace root, and `~/` and absolute paths work
too. `/vibe-cop on` creates it, and `on` and `status` print it.

Patches are still blocked there. A directory that would hold the workspace root
or the config file (`.`, `~`, `.git` with a `.git/vrc`) is ignored, and `status`
says so. A directory inside the workspace that is not gitignored shows up in
`git status`.

## Auto memory

Claude Code's auto memory stays writable in vibe-cop mode, so Claude keeps
saving what it learns about you and the project. The hook allows writes under
`<config dir>/projects/<project>/memory/` (`~/.claude` unless
`CLAUDE_CONFIG_DIR` is set) for any project, since the `<project>` key follows
the git repo. A custom `autoMemoryDirectory` setting is not covered. Patches are
still blocked there.

To keep Claude from writing memory while the mode is on, add this line to the
workspace `.vrc`:

```
memory: off
```

`on` and `status` print whether memory is writable.

## Workspace config (.vrc)

A workspace can choose which files the advisor may edit with a config file at
`.vrc` in the workspace root (the git worktree top, or the project directory
outside git), or at `.git/vrc` to keep it out of version control. `.vrc` wins
when both exist; linked worktrees share the main checkout's `.git/vrc`. Apart
from `default: on`, the config only takes effect while the mode is on.

Lines starting with `mode:`, `scratch-dir:`, `default:`, or `memory:` are
directives and may appear anywhere. `mode:` is required once the file lists
patterns; `scratch-dir:` (see Scratch dir), `default:` (see Default on), and
`memory:` (see Auto memory) are optional. Every other line is a gitignore-style
pattern, relative to the workspace root:

```
mode: allowlist
scratch-dir: .git/vibe-cop
default: on
docs/
tests/**/*.py
/CHANGELOG.md
```

- `mode: allowlist`: only files matching a pattern may be written. Every other
  workspace file is read-only, gitignored artifacts included.
- `mode: blocklist`: any workspace file may be written except those matching a
  pattern.

Patterns are evaluated by git's own gitignore matcher, so the usual rules apply:
`#` comments, `!` negation, a trailing `/` for directories only, a leading or
inner `/` anchors to the root, and `**` spans directories. As in gitignore, a
negation cannot re-include a file inside a listed directory: `docs/` plus
`!docs/x.md` still covers `docs/x.md`, so write `docs/*` plus `!docs/x.md`.

Listing a directory covers everything beneath it, including the contents of
symlinked subdirectories. Each target is checked both by the path as given and
by its symlink-resolved path, and a match on either counts, so an unlisted
symlink pointing into a listed directory is treated as listed.

`/vibe-cop status` (and `/vibe-cop on`) prints the config, its patterns, and the
existing paths they match, with a matched directory shown once as `dir/` and the
list capped at 50 entries. A pattern can match nothing yet and still apply to new
files.

Regardless of the config, the config file and `.git/` (outside the scratch dir)
are never writable in vibe-cop mode. Writes outside the workspace keep the
default rule (`/tmp` scratch, the scratch dir, auto memory, and gitignored
artifacts). A config with patterns but no mode line, or with a mode line that
is not `allowlist` or `blocklist`, blocks all workspace writes until it is
fixed. Like the default rule, the config gates the `Write`, `Edit`, and
`NotebookEdit` tools; file writes from Bash are left to the persona.

## Limitation

No hook can be fully airtight: a command such as `python -c "open('f','w')"`
creates a file without going through a matched tool call. Likewise, the patch
guard catches diff output, but not an edited copy of a source file in scratch,
since that is indistinguishable from other scratch files. Nor can a hook judge
how long an example in chat is. The persona is the
real contract; the hooks catch the common tools. Treat a denial as a reminder to
switch back to advising.

## Layout

```
.claude-plugin/plugin.json        plugin manifest
.claude-plugin/marketplace.json   marketplace listing, so the repo installs with /plugin
hooks/hooks.json                  registers the PreToolUse, UserPromptSubmit, and SessionStart hooks
commands/vibe-cop.md              the /vibe-cop on|off|status command
scripts/vibe-cop-toggle.sh        flips the per-session state, prints the persona
scripts/vibe-cop-hook.sh          the enforcement + reminder hook
scripts/selftest.sh               assert-based check of the guard logic
.github/workflows/ci.yml          runs shellcheck and the selftest on push and PR
```

## Test

```
bash scripts/selftest.sh
```

Builds a throwaway git repo and asserts the deny/allow decisions across Write,
Edit, and Bash cases with the mode on and off, with and without a `.vrc` /
`.git/vrc` config.
