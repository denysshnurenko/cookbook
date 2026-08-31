#!/usr/bin/env zsh
# harness worktree-preflight: what would be LOST if this worktree were destroyed right now.
#
# Called by both destroyers — worktree-rm.sh (⌘⌥⇧T) and worktree-archive.sh (the skill) — because
# they are independent paths and a check living in only one of them protects only half the ways
# a worktree dies. Prints findings to stderr; exits 1 when something blocks, 0 when clear.
#
# Why it exists: the destroyers ran `git worktree remove --force`, `git branch -D` and `docker
# rm -f` with no check at all. Uncommitted work, unpushed commits and an unmerged branch all went
# without a question — the safety lived in the PROCEDURE around the scripts (the cookbook told the
# agent to check `git status --porcelain` first), which means it protected exactly the callers who
# remembered to read it. On 2026-08-28 ten dev servers were found still running four days after
# their shells died, which is the same class: nothing verified the worktree was quiet.
#
# It checks only what cannot be recovered afterwards. Ticket status is deliberately NOT here: a
# worktree on an unfinished ticket is a normal thing to archive, so it would be a nag, not a guard.
#
# usage: worktree-preflight.sh <worktree-path>              → exit 0 clear, 1 blocked
#        worktree-preflight.sh <worktree-path> --list-jobs → print the job pids, exit 0
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

in="${1:?usage: worktree-preflight.sh <worktree-path>}"
wt="$(cd "$in" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" \
  || { print -u2 "🚫 not a git worktree: $in"; exit 1 }
blocked=0

# 1. Uncommitted changes — the one loss nothing can undo.
dirty="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
(( dirty > 0 )) && { print -u2 "🚫 $dirty uncommitted change(s)"; blocked=1 }

# 2. Commits that exist nowhere else. A branch with NO upstream has never been pushed, so every
# commit it carries is local — `@{u}` fails there, which is why the no-upstream case is separate
# rather than folded into the same rev-list.
branch="$(git -C "$wt" symbolic-ref --short -q HEAD || echo '')"
if [[ -n "$branch" ]]; then
  if git -C "$wt" rev-parse --verify -q "@{u}" >/dev/null 2>&1; then
    ahead="$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    (( ahead > 0 )) && { print -u2 "🚫 $ahead commit(s) not pushed to ${branch}'s upstream"; blocked=1 }
  else
    base="$(git -C "$wt" rev-parse --verify -q origin/master >/dev/null 2>&1 && echo origin/master || echo origin/dev)"
    only="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
    (( only > 0 )) && { print -u2 "🚫 branch '$branch' was never pushed — $only commit(s) exist only here"; blocked=1 }
  fi
fi

# 3. Long-running JOBS in the worktree — dev servers, watchers, test runners. Filtered, and the
# filter is the whole value: an unfiltered cwd match reports the session's own claude, its fish,
# agtermctl, st-watch, caffeinate and a stray `sleep`, i.e. eight lines of noise that teach you to
# skip the warning. Worse, archive.sh KILLS this list — unfiltered it would kill the user's claude.
# Residents of a healthy worktree are excluded; anything else is a job that should be stopped
# deliberately, not have its directory deleted underneath it.
#
# Two things are excluded before the name filter is even consulted, because neither is a job and
# both made the guard block on ITSELF:
#
#   - This run's own ancestry. ⌘⌥⇧T opens worktree-rm.sh INSIDE an overlay whose cwd is the
#     worktree, so its wrapper shells (`-sh -c ( eval "$AGTERM_OVL_CMD" )`) sit in the lsof set —
#     and `$$` alone excludes only this script. Reported, they read as blockers; killed by
#     archive.sh, they are the teardown killing itself half-way through.
#   - A pid whose args come back EMPTY. lsof snapshots pids, then `ps` runs a moment later; a
#     short-lived child (this pipeline's own lsof/awk/sort, or any command an agent session just
#     ran here) is already gone. The name filter is a `case` over $args, and an empty string
#     matches no pattern, so every such pid fell through as a blocker with a blank command line —
#     the `pid 83461 still running here:` lines with nothing after the colon.
typeset -gA _wt_self
_p=$$
while [[ -n "$_p" && "$_p" != 0 && "$_p" != 1 ]]; do
  _wt_self[$_p]=1
  _p="$(ps -p "$_p" -o ppid= 2>/dev/null | tr -d ' ')"
done

worktree_jobs() {
  lsof -d cwd -Fpn 2>/dev/null | awk -v w="${1:A}/" '
    /^p/ { pid = substr($0,2) }
    /^n/ { d = substr($0,2); if (d == substr(w,1,length(w)-1) || index(d, w) == 1) print pid }
  ' | sort -u | while read -r pid; do
    [[ -z "$pid" || -n "${_wt_self[$pid]:-}" ]] && continue
    args="$(ps -p "$pid" -o args= 2>/dev/null)"
    [[ -z "$args" ]] && continue
    case "$args" in
      *claude*|*/fish*|*zsh*|*bash*|*agtermctl*|*caffeinate*|*"sleep "*|*.claude/plugins/*) continue ;;
    esac
    print -r -- "$pid"
  done
}

if [[ "${2:-}" == --list-jobs || "${1:-}" == --list-jobs ]]; then
  worktree_jobs "$wt"; exit 0
fi

for pid in ${(f)"$(worktree_jobs "$wt")"}; do
  [[ -z "$pid" ]] && continue
  print -u2 "🚫 pid $pid still running here: $(ps -p $pid -o args= 2>/dev/null | sed 's|/Users/[^/]*|~|' | cut -c1-58)"
  blocked=1
done

# 4. An overlay open on this worktree's session — revdiff with unsaved annotations is the case
# that hurts, and it is invisible from the filesystem.
#
# EXCEPT the overlay we are ourselves running in. ⌘⌥⇧T is `agtermctl session overlay open
# worktree-rm.sh --cwd "$AGT_SESSION_PWD"` (keymap.conf), i.e. the destroyer is an overlay on the
# very session it is about to tear down — so this check found its own and ⌘⌥⇧T could never once
# succeed. An overlay child carries AGTERM_OVL_CMD and the AGTERM_SESSION_ID of its session, and
# never AGTERM_PANE; skip exactly that session id, so a SECOND overlay (a real revdiff) on the same
# session still blocks.
own=""
[[ -n "${AGTERM_OVL_CMD:-}" ]] && own="${AGTERM_SESSION_ID:-}"
sess="$(agtermctl tree --json 2>/dev/null | jq -r --arg w "$wt" --arg own "$own" '
  .result.tree.workspaces[].sessions[]
  | select(.cwd == $w)
  | select(.overlay != false and .overlay != null)
  | select($own == "" or (.id | ascii_downcase) != ($own | ascii_downcase))
  | .name' 2>/dev/null)"
[[ -n "$sess" ]] && { print -u2 "🚫 an overlay is open in session '$sess' (revdiff? unsaved annotations)"; blocked=1 }

(( blocked )) && { print -u2 "   → nothing was touched. Re-run with --force to destroy anyway."; exit 1 }
exit 0
