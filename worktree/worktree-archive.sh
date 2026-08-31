#!/usr/bin/env zsh
# .claude/skills/worktree-archive/archive.sh — non-interactive teardown core for the
# `worktree-archive` skill. For a given worktree it: archives the DB (this repo's
# infra/worktree/archive.sh — drops the Postgres container + volume + Caddy fragment)
# with a generic docker fallback, removes the git worktree, and deletes its LOCAL
# branch. It does NOT delete the REMOTE branch (the skill does that as a separate,
# explicitly-confirmed step) and does NOT close any agterm session.
#
# Safety: refuses on the MAIN checkout; never deletes master/dev; targets the ORIGINAL
# branch the worktree was created for (recorded by the `worktree` skill's create.sh),
# so a HEAD that drifted after creation is reported, not deleted.
#
# Usage:  archive.sh <worktree-path>
# Output: progress on STDERR; ONE summary line on STDOUT for the skill to parse:
#   ARCHIVED slug=<slug> branch=<orig_branch> remote=<yes|no> drifted=<branch-or-empty>
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

in="${1:?usage: archive.sh <worktree-path>}"
wt="$(cd "$in" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" \
  || { print -u2 "🚫 not a git worktree: $in"; exit 1; }
main="$(git -C "$wt" worktree list --porcelain | sed -n '1s/^worktree //p')"
branch="$(git -C "$wt" symbolic-ref --short -q HEAD || echo '?')"
slug="${wt:t}"

if [[ "$wt" == "$main" ]]; then
  print -u2 "🚫 this is the MAIN checkout, not a worktree — refusing to archive."; exit 1
fi

# original branch this worktree was created for (read BEFORE removing the worktree, since
# `git worktree remove` deletes the admin dir that holds the marker). Falls back to HEAD.
gitdir="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)"
orig_branch="$branch"
[[ -n "$gitdir" && -f "$gitdir/harness-original-branch" ]] && orig_branch="$(<"$gitdir/harness-original-branch")"

remote=no
[[ "$orig_branch" != master && "$orig_branch" != dev && "$orig_branch" != "?" ]] \
  && git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$orig_branch" && remote=yes

# 1. archive the workspace DB (repo's own archive.sh) — best-effort, synchronous.
# Run from a THROWAWAY EMPTY DIR, not from the worktree: archive.sh derives a
# process sweep from its own cwd and that sweep is an UNFILTERED cwd match, so it
# also kills the agterm shell of any session sitting in this worktree — which
# closes that session and, on the ⌘⌥⇧T path, the overlay the teardown itself runs
# in. Jobs are killed below from the preflight's filtered list instead. What
# archive.sh tears down is named from WORKTREE_NAME, never from cwd.
if [[ -f "$wt/infra/worktree/archive.sh" ]]; then
  print -u2 "🧹 infra/worktree/archive.sh (WORKTREE_NAME=$slug)"
  ( cd "$(mktemp -d)"; WORKTREE_NAME="$slug" zsh "$wt/infra/worktree/archive.sh" ) 1>&2 \
    || print -u2 "   ⚠️  archive.sh error — continuing with worktree removal"
fi
# 1b. generic docker fallback: catch any db-<slug> container archive.sh's exact-name
#     match might have missed (e.g. base port shifted the derived name).
slug_lc="$(print -r -- "$slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
if [[ -n "$slug_lc" ]]; then
  for c in ${(f)"$(docker ps -aq --filter "name=db-${slug_lc}" 2>/dev/null)"}; do
    [[ -n "$c" ]] && { print -u2 "🐳 docker rm -f (db-${slug_lc})"; docker rm -f "$c" 1>&2 || print -u2 "   ⚠️  docker rm failed for $c"; }
  done
fi

# 2. remove the worktree
# PREFLIGHT — what would be lost if this ran right now (uncommitted work, unpushed commits, live
# processes, an open overlay). Shared with worktree-rm.sh rather than duplicated: they are
# independent teardown paths, and a check in only one protects half the ways a worktree dies.
# `--force` as the 2nd arg skips it, which is what the auto-archive idea would eventually pass
# once its own conditions are checked upstream.
if [[ "${2:-}" != --force ]]; then
  "$HOME/.config/harness/worktree-preflight.sh" "$wt" || exit 1
fi
# Kill exactly what the preflight reports, by asking it — the filter that keeps claude and fish
# off that list lives in one place, so the warning and the kill can never disagree.
for pid in ${(f)"$("$HOME/.config/harness/worktree-preflight.sh" "$wt" --list-jobs 2>/dev/null)"}; do
  [[ -n "$pid" ]] && { print -u2 "🔪 kill $pid (job running in the worktree)"; kill "$pid" 2>/dev/null }
done

print -u2 "🪓 git worktree remove --force"
if ! git -C "$main" worktree remove --force "$wt" 1>&2; then
  print -u2 "💥 git worktree remove failed — aborting (branch left intact)."; exit 1
fi

# 3. delete the LOCAL branch (the ORIGINAL one; never master/dev)
if [[ "$orig_branch" != master && "$orig_branch" != dev && "$orig_branch" != "?" ]]; then
  print -u2 "✂️  git branch -D $orig_branch"
  git -C "$main" branch -D "$orig_branch" >/dev/null 2>&1 || print -u2 "   (local branch already gone)"
fi

drifted=""
[[ "$branch" != "$orig_branch" && "$branch" != "?" ]] && drifted="$branch"

# 4. sweep ghost branches (local, remote gone, checked out nowhere) — the worktree just
# removed often leaves side branches behind (`chore/…`, `docs/…` made inside it whose PRs
# merged); after this removal they are exactly that. Best-effort, stderr, never fatal.
"$HOME/.config/harness/worktree-prune-ghosts.sh" "$main" 1>&2 2>/dev/null || true

print -u2 "🎉 archived + removed worktree: $slug"
print -r -- "ARCHIVED slug=${slug} branch=${orig_branch} remote=${remote} drifted=${drifted}"
