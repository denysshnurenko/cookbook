#!/usr/bin/env zsh
# harness worktree-new: create a git worktree (sibling dir) + open an agterm
# session in it, then auto-configure it (worktree-setup.sh) inside that session.
# Runs in an agterm overlay; prompts for the branch name and the base.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Optional defaults, so another flow can hand this one a proposal instead of duplicating it
# (the task picker does: it knows the ticket, this script knows how to make a worktree).
#   --branch <name>   prefill the branch prompt
#   --base <ref>      prefill the base prompt
# Both stay EDITABLE on purpose: a branch name generated from a ticket title is a guess, and
# it outlives the guess as a directory, a session name and a remote ref.
branch_default=""; base_default=""
while (( $# )); do
  case "$1" in
    --branch) branch_default="${2:-}"; shift 2 ;;
    --base)   base_default="${2:-}";   shift 2 ;;
    *) print "🚫 unknown argument: $1"; sleep 3; exit 1 ;;
  esac
done

root="$(git -C "${AGT_SESSION_PWD:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
  || { print "🚫 not a git repo (open this from a repo session)"; sleep 3; exit 1; }
cd "$root"

# anchor on the main checkout (a worktree of a worktree is confusing)
main="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
[[ -n "$main" ]] && { root="$main"; cd "$root"; }
repo="${root:t}"
current="$(git symbolic-ref --short -q HEAD || echo master)"

print "🌱  new worktree in ${repo}\n"
if [[ -n "$branch_default" ]]; then
  print -n "👉  branch name [${branch_default}]: "
else
  print -n "👉  branch name: "
fi
read -r branch
branch="${branch:-$branch_default}"
[[ -n "$branch" ]] || { print "🙅 cancelled."; sleep 1; exit 1; }
slug="${branch//\//-}"
wt="${root:h}/${repo}.worktrees/${slug}"

base_fallback="${base_default:-master}"
print -n "🌳  base branch [${base_fallback}]  ('.' = current '${current}'): "
read -r base_in
base="${base_in:-$base_fallback}"
[[ "$base" == "." || "$base" == "HEAD" ]] && base="$current"

if [[ -e "$wt" ]]; then print "\n💥 already exists: $wt"; sleep 3; exit 1; fi
if git show-ref --verify --quiet "refs/heads/$branch"; then print "\n💥 branch already exists: $branch"; sleep 3; exit 1; fi

# resolve the start point: current branch → local (keeps unpushed work);
# otherwise fetch origin/<base> and branch off it (fresh), else off local <base>.
if [[ "$base" == "$current" ]]; then
  start="$base"
  print "\n🌿 git worktree add  (-b ${branch} off local ${base})"
else
  print "\n📡 git fetch origin ${base}…"
  git fetch --quiet origin "$base" 2>/dev/null || print "   (fetch failed — using what's local)"
  # Sweep ghost branches while we are here: local, remote gone, checked out nowhere. This is
  # the moment they get noticed for free — see worktree-prune-ghosts.sh for the rule.
  "$HOME/.config/harness/worktree-prune-ghosts.sh" "$root" 2>/dev/null | grep -v "no ghost" || true
  if git show-ref --verify --quiet "refs/remotes/origin/$base"; then start="origin/$base"; else start="$base"; fi
  print "🌿 git worktree add  (-b ${branch} off ${start})"
fi

if ! git worktree add "$wt" -b "$branch" "$start"; then
  print "\n💥 worktree add failed (does base '${base}' exist?)"; sleep 3; exit 1
fi

# remember the ORIGINAL branch this worktree was created for, in the worktree's
# own git admin dir (not the working tree — keeps it out of `git status`, and
# git deletes it automatically on `git worktree remove`). worktree-rm.sh reads
# this back so branch cleanup targets the right branch even if HEAD later
# drifts to something else inside this worktree.
gitdir="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)"
[[ -n "$gitdir" ]] && print -r -- "$branch" > "$gitdir/harness-original-branch"

# pre-seed the solidtime task binding from the branch's ticket id (silent, best-effort)
"$HOME/.config/harness/solidtime/st" resolve --cwd "$wt" >/dev/null 2>&1 || true

# §F semi-auto-create (design §C): ticket has NO solidtime task yet → offer to create
# it right here, before provisioning (this overlay is interactive). Declining is safe:
# the cmd+s picker offers the same creation later, with full project/title editing.
prop="$("$HOME/.config/harness/solidtime/st" propose --cwd "$wt" --json 2>/dev/null)"
if [[ "$(jq -r '.propose // false' <<<"$prop" 2>/dev/null)" == "true" ]]; then
  tname="$(jq -r '.name' <<<"$prop")"
  pname="$(jq -r '.projects[0].name' <<<"$prop")"
  pid="$(jq -r '.projects[0].id' <<<"$prop")"
  print ""
  if read -q "yn?⏱ no solidtime task for this ticket — create '${tname}' in ${pname}? [y/N] "; then
    print ""
    created="$("$HOME/.config/harness/solidtime/st" create-task "$tname" --project "$pid" --json 2>/dev/null)"
    tid="$(jq -r '.id // empty' <<<"$created" 2>/dev/null)"
    if [[ -n "$tid" ]]; then
      "$HOME/.config/harness/solidtime/st" bind "$tid" --cwd "$wt" >/dev/null 2>&1
      print "⏱ solidtime: bound → ${tname}"
    else
      print "⏱ solidtime: create failed — cmd+s in the session will offer it again"
    fi
  else
    print "\n⏱ skipped — cmd+s in the new session offers it again"
  fi
fi

# start the timer on the new ticket right away (worktree creation IS work on it) —
# unless a sticky meeting-like task is running; the watcher keeps following focus after
tid="$(cat "$gitdir/harness-solidtime-task" 2>/dev/null)"
if [[ -n "$tid" ]]; then
  "$HOME/.config/harness/solidtime/st" start "$tid" --unless-sticky 2>/dev/null | tail -1
fi

# .ralphex is untracked (git-ignored), so `git worktree add` never brings it along —
# copy it over so ralphex's config is available in the new worktree. Skip progress/
# (historical plan logs, not needed per-worktree and just grows over time).
if [[ -d "$root/.ralphex" ]]; then
  cp -R "$root/.ralphex" "$wt/.ralphex"
  rm -rf "$wt/.ralphex/progress" "$wt/.ralphex/agterm-bus"
  print "📋 copied .ralphex (skipping progress/, agterm-bus/)"
fi

# .claude/settings.local.json is git-ignored too (it holds this checkout's approved
# permissions — 316 entries in hopecloud), so a fresh worktree starts with none and an
# agent there re-asks for everything. Copy, not symlink: Claude Code rewrites this file
# on every approval, and a write-temp-then-rename would replace the link with a regular
# file and silently detach the worktree from the shared one.
# NB: worktree-create.sh (the `worktree` skill's path) carries the same block — both
# entry points must stay in step.
if [[ -f "$root/.claude/settings.local.json" ]]; then
  mkdir -p "$wt/.claude"
  cp "$root/.claude/settings.local.json" "$wt/.claude/settings.local.json"
  print "🔐 copied .claude/settings.local.json"
fi

print "🪟 opening session + provisioning…"
sid="$(agtermctl session new --json --workspace active --cwd "$wt" --name "$slug" 2>/dev/null | jq -r '.result.id // empty')"
if [[ -n "$sid" ]]; then
  sleep 2   # let the new fish session finish starting before we type into it
  # provision, then drop straight into claude in the worktree (';' → claude runs
  # even if provisioning fails, so you can ask it to fix the cause on the spot).
  # --remote-control '<slug>' names the Remote Control session after the worktree,
  # so it shows up as '<slug>' in claude.ai/code / the mobile app (matches the
  # worktree skill's worktree-open-session.sh). claude.fish passes the flag through
  # and still pins --session-id to this tab's uuid.
  agtermctl session type "~/.config/harness/worktree-setup.sh '${branch}'; claude --remote-control '${slug}'"$'\n' --target "$sid" 2>/dev/null
  # PIN the conversation for the next launch, instead of relying on agterm's auto-capture.
  # Auto-capture records a pane's foreground only at a CLEAN quit; a reboot, a crash or a
  # power loss captures nothing, and every worktree session then comes back as a bare shell
  # (measured three times: only explicitly pinned sessions survived). The conversation id is
  # known right here: the claude wrapper binds a tab's first conversation to the tab's own
  # uuid, lowercase. `--resume` on a not-yet-created conversation is rescued by the same
  # wrapper (it creates it under that id), so pinning before claude even starts is safe.
  agtermctl session restore "claude --resume $(printf '%s' "$sid" | tr '[:upper:]' '[:lower:]') --remote-control '${slug}'" --target "$sid" 2>/dev/null
  print "\n🎉 worktree created + session opened.\n   🧪 provisioning runs in '${slug}', then 🤖 claude starts."
else
  print "\n🎉 worktree created at:\n   $wt\n   (couldn't auto-open a session — cd there and run: worktree-setup.sh '${branch}')"
fi
sleep 2
