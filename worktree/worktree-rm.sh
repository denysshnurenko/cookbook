#!/usr/bin/env zsh
# harness worktree-rm: tear down the CURRENT worktree — archive (drop the DB
# container etc.), git worktree remove, delete the branch, and close the session.
# Runs in an agterm overlay from within the worktree's session. Refuses on main.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

wt="$(git -C "${AGT_SESSION_PWD:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
  || { print "🚫 not a git repo"; sleep 3; exit 1; }
branch="$(git -C "$wt" symbolic-ref --short -q HEAD || echo '?')"
main="$(git -C "$wt" worktree list --porcelain | sed -n '1s/^worktree //p')"
# stable name for docker/infra teardown: the worktree's OWN directory name, fixed
# at creation time. NOT $branch — if the checked-out branch was ever switched
# inside this worktree after creation, $branch drifts from what the container/
# volume were actually named, and teardown silently misses them (looks like
# "already gone" instead of the name just being wrong).
wt_slug="${wt:t}"

# the branch this worktree was ORIGINALLY created for (written by worktree-new.sh
# into the worktree's git admin dir — read it BEFORE step 2 deletes that dir).
# Falls back to $branch (current HEAD) for worktrees created before this existed.
gitdir="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)"
orig_branch="$branch"
if [[ -n "$gitdir" && -f "$gitdir/harness-original-branch" ]]; then
  orig_branch="$(<"$gitdir/harness-original-branch")"
fi

if [[ "$wt" == "$main" ]]; then
  print "🚫 this is the MAIN checkout, not a worktree — refusing to remove."; sleep 3; exit 1
fi

# the session sitting in this worktree (to close at the very end)
sid="${AGT_SESSION_ID:-}"
[[ -z "$sid" ]] && sid="$(agtermctl tree --json 2>/dev/null \
  | jq -r --arg wt "$wt" '.result.tree.workspaces[].sessions[] | select(.cwd==$wt) | .id' | head -1)"

print "🗑️   remove worktree"
print "    📂 $wt"
print "    🌿 $branch\n"
print -n "⚠️   type 'yes' to confirm teardown: "
read -r ans
[[ "$ans" == "yes" ]] || { print "🙅 cancelled."; sleep 1; exit 1; }

# had_warning gates a "press any key" pause before the auto session-close below —
# the script closes its OWN hosting session/overlay at the end, so anything
# printed just before that is normally gone before you can read it. Only pause
# when there's actually something worth reading.
had_warning=0

# 0. Preflight: refuse while something would be lost. Same script archive.sh uses — see there.
if [[ "${1:-}" != --force ]]; then
  "$HOME/.config/harness/worktree-preflight.sh" "$wt" || {
    print "\n⛔ teardown cancelled — nothing was touched."; sleep 6; exit 1 }
fi

# 1. archive (drop DB container / volume / caddy) — best-effort. Output is
# captured (not streamed) so we can scan it for a warning before deciding
# whether to pause for you to read it.
if [[ -f "$wt/infra/worktree/archive.sh" ]]; then
  print "\n🧹 infra/worktree/archive.sh"
  archive_out="$( ( cd "$wt"; WORKTREE_NAME="$wt_slug" zsh "$wt/infra/worktree/archive.sh" ) 2>&1 )"
  archive_rc=$?
  [[ -n "$archive_out" ]] && print -r -- "$archive_out"
  (( archive_rc != 0 )) && { print "    💥 archive error — continuing"; had_warning=1; }
  [[ "$archive_out" == *"⚠️"* ]] && had_warning=1
fi

# 1b. generic fallback + belt-and-braces re-check: catches repos with no
#     infra/worktree/archive.sh at all, and any container/volume archive.sh's
#     exact-name match might have missed.
slug_lc="$(print -r -- "$wt_slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
if [[ -n "$slug_lc" ]]; then
  for c in ${(f)"$(docker ps -aq --filter "name=db-${slug_lc}" 2>/dev/null)"}; do
    if [[ -n "$c" ]]; then
      print "🐳 docker rm -f (db-${slug_lc})"
      docker rm -f "$c" || { print "    ⚠️  docker rm failed for $c"; had_warning=1; }
    fi
  done
  for v in ${(f)"$(docker volume ls -q --filter "name=db_${slug_lc//-/_}" 2>/dev/null)"}; do
    [[ -n "$v" ]] && { docker volume rm "$v" || { print "    ⚠️  docker volume rm failed for $v"; had_warning=1; }; }
  done
fi

# 2. remove the worktree
print "\n🪓 git worktree remove"
cd "$main"
if ! git worktree remove --force "$wt"; then
  print "\n💥 git worktree remove failed — aborting (branch + session left intact)."; sleep 4; exit 1
fi

# 3. delete the branch (force; never master/dev) — the ORIGINAL branch this
# worktree was created for, local then remote. Using $orig_branch (not $branch)
# so a HEAD that drifted to something else inside this worktree doesn't leave
# the real target branch behind.
if [[ "$orig_branch" != master && "$orig_branch" != dev && "$orig_branch" != "?" ]]; then
  print "✂️  git branch -D $orig_branch"
  if ! err=$(git branch -D "$orig_branch" 2>&1 >/dev/null); then
    [[ "$err" == *"not found"* ]] || { print "    ⚠️  local branch delete failed: $err"; had_warning=1; }
  fi

  print "☁️  git push origin --delete $orig_branch"
  if ! err=$(git push origin --delete "$orig_branch" 2>&1 >/dev/null); then
    [[ "$err" == *"remote ref does not exist"* ]] || { print "    ⚠️  remote branch delete failed: $err"; had_warning=1; }
  fi
fi

# HEAD drifted to a different branch after creation (e.g. checked out something
# else to inspect it) — never auto-delete that one, it might be shared/important
# (a release branch, someone else's work). Just flag it so it isn't forgotten.
if [[ "$branch" != "$orig_branch" && "$branch" != "?" ]]; then
  print "    ⚠️  worktree had drifted to branch '$branch' (created for '$orig_branch') — left untouched"
  had_warning=1
fi

agtermctl notify "🗑️ removed worktree: $orig_branch" --title "harness" 2>/dev/null || true
print "\n🎉 removed worktree + branch — closing session…"

if (( had_warning )); then
  print "\n⚠️   something above needs a look — press any key to close"
  read -k 1 -s -r
else
  sleep 1
fi

# 4. close the worktree's session (also tears down this overlay)
if [[ -n "$sid" ]]; then
  agtermctl session close --target "$sid" 2>/dev/null
else
  print "    (couldn't find the session to close — close it with cmd+w)"; sleep 2
fi
