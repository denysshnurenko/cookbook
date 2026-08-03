#!/usr/bin/env zsh
# harness worktree-create: NON-INTERACTIVE core of worktree-new.sh — create a git
# worktree (sibling dir) for a NEW branch off a base, copy .ralphex, and record the
# original branch. No prompts, no fzf, no agterm, no TTY: branch + base are ARGS, so
# this runs anywhere — including Claude Code over Remote Control (the phone app),
# which is exactly why it exists (the `worktree` skill calls it). Provisioning is a
# separate step (worktree-setup.sh), same split as the agterm overlay flow.
#
# Usage:  worktree-create.sh <branch> [base]
#   base default: master;  '.' or 'HEAD' = the repo's current branch.
# Output: progress + git output go to STDERR; the created worktree's absolute path is
#   the ONLY thing on STDOUT (last line) so a caller can `wt=$(worktree-create.sh …)`.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

branch="${1:-}"
[[ -n "$branch" ]] || { print -u2 "usage: worktree-create.sh <branch> [base]"; exit 2; }
base_in="${2:-master}"

root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { print -u2 "🚫 not a git repo — run this from inside the repo you want a worktree of"; exit 1; }
cd "$root"

# anchor on the MAIN checkout (a worktree of a worktree is confusing)
main="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
[[ -n "$main" ]] && { root="$main"; cd "$root"; }
repo="${root:t}"
current="$(git symbolic-ref --short -q HEAD || echo master)"

slug="${branch//\//-}"
wt="${root:h}/${repo}.worktrees/${slug}"

base="$base_in"
[[ "$base" == "." || "$base" == "HEAD" ]] && base="$current"

if [[ -e "$wt" ]]; then print -u2 "💥 already exists: $wt"; exit 1; fi
if git show-ref --verify --quiet "refs/heads/$branch"; then print -u2 "💥 branch already exists: $branch"; exit 1; fi

# resolve the start point: base == current → local (keeps unpushed work); otherwise
# fetch origin/<base> and branch off it (fresh), else off local <base>.
if [[ "$base" == "$current" ]]; then
  start="$base"
  print -u2 "🌿 git worktree add -b ${branch} off local ${base}"
else
  print -u2 "📡 git fetch origin ${base}…"
  git fetch --quiet origin "$base" 2>/dev/null || print -u2 "   (fetch failed — using what's local)"
  if git show-ref --verify --quiet "refs/remotes/origin/$base"; then start="origin/$base"; else start="$base"; fi
  print -u2 "🌿 git worktree add -b ${branch} off ${start}"
fi

if ! git worktree add "$wt" -b "$branch" "$start" 1>&2; then
  print -u2 "💥 worktree add failed (does base '${base}' exist?)"; exit 1
fi

# remember the ORIGINAL branch this worktree was created for, in the worktree's own
# git admin dir (out of `git status`; git removes it on `git worktree remove`).
# worktree-rm.sh reads it back so branch cleanup targets the right branch even if
# HEAD later drifts inside the worktree.
gitdir="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)"
[[ -n "$gitdir" ]] && print -r -- "$branch" > "$gitdir/harness-original-branch"

# pre-seed the solidtime task binding from the branch's ticket id (silent, best-effort)
"$HOME/.config/harness/solidtime/st" resolve --cwd "$wt" >/dev/null 2>&1 || true

# §F, split by what needs a human. worktree-new.sh (cmd+opt+t) does BOTH halves in code
# because it runs in an overlay with a TTY; here there is none, and that asymmetry is how
# an agent-created worktree ended up with no task at all — the skill documents the step,
# but instructions get skipped and code does not.
#
# So: the half that needs no decision runs here, and the half that does prints itself
# LOUDLY at the moment of creation instead of relying on the agent recalling step 3b.
# Everything goes to stderr — stdout is the worktree path, which the caller captures.
prop="$("$HOME/.config/harness/solidtime/st" propose --cwd "$wt" --json 2>/dev/null)"
if [[ "$(jq -r '.propose // false' <<<"$prop" 2>/dev/null)" == "true" ]]; then
  tname="$(jq -r '.name' <<<"$prop")"
  tnum="$(jq -r '.num' <<<"$prop")"
  pname="$(jq -r '.projects[0].name' <<<"$prop")"
  pid="$(jq -r '.projects[0].id' <<<"$prop")"
  ST="\$HOME/.config/harness/solidtime/st"
  print -u2 ""
  print -u2 "⏱  NO SOLIDTIME TASK for this ticket — the worktree is UNBOUND."
  print -u2 "   1. Get the REAL title from DOTT — the derived one below comes from the branch"
  print -u2 "      slug and silently drops whatever the slug left out (e.g. derived"
  print -u2 "      '#42 | Export button on reports' vs the actual"
  print -u2 "      '#42 | As an admin, I can use the Export button on reports'):"
  print -u2 "        dott_get_issue(number: $tnum)  →  use its .name"
  print -u2 "      Fall back to the derived title only if DOTT has no such issue or is unreachable."
  print -u2 "   2. ASK the user to confirm title + project, then:"
  print -u2 "        $ST create-task '#$tnum | <title>' --project '$pid' --json   # → .id"
  print -u2 "        $ST bind '<task-id>' --cwd '$wt'"
  print -u2 "        $ST start '<task-id>' --unless-sticky"
  print -u2 "   derived (fallback only): $tname   ·   project: $pname"
  print -u2 ""
fi

# Timer start needs no confirmation, so unlike creation it belongs in code: creating a
# worktree IS work on its ticket. Only fires when something actually bound it (resolve
# above, or a previous run). --unless-sticky leaves a running meeting-like timer alone.
tid="$(cat "$gitdir/harness-solidtime-task" 2>/dev/null)"
if [[ -n "$tid" ]]; then
  "$HOME/.config/harness/solidtime/st" start "$tid" --unless-sticky 2>/dev/null | tail -1 >&2
fi

# .ralphex is untracked (git-ignored), so `git worktree add` never brings it — copy
# it so ralphex config is present. Skip progress/ (historical logs, grows over time).
if [[ -d "$root/.ralphex" ]]; then
  cp -R "$root/.ralphex" "$wt/.ralphex"
  rm -rf "$wt/.ralphex/progress" "$wt/.ralphex/agterm-bus"
  print -u2 "📋 copied .ralphex (skipping progress/, agterm-bus/)"
fi

# .claude/settings.local.json is git-ignored too (it holds this checkout's approved
# permissions — 316 entries in hopecloud), so a fresh worktree starts with none and an
# agent there re-asks for everything. Copy, not symlink: Claude Code rewrites this file
# on every approval, and a write-temp-then-rename would replace the link with a regular
# file and silently detach the worktree from the shared one.
if [[ -f "$root/.claude/settings.local.json" ]]; then
  mkdir -p "$wt/.claude"
  cp "$root/.claude/settings.local.json" "$wt/.claude/settings.local.json"
  print -u2 "🔐 copied .claude/settings.local.json"
fi

print -u2 "🎉 worktree created: $wt"
print -r -- "$wt"   # STDOUT: the path, for the caller to capture / cd into
