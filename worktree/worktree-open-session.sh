#!/usr/bin/env zsh
# harness worktree-open-session: when the personal `worktree` skill runs from INSIDE
# agterm, open a NEW agterm session in the freshly-created worktree and kick off the
# personal provisioning (~/.config/harness/worktree-setup.sh) + claude there — same
# result as the cmd+opt+t worktree overlay (worktree-new.sh). claude starts with
# --remote-control '<rcname>' so the session shows up readably named in Remote Control
# (rc-name.sh: ticket id first, ~30 chars — a full branch slug truncates on mobile).
#
# The session is pinned to THIS shell's agterm window/workspace (AGTERM_WINDOW_ID /
# AGTERM_WORKSPACE_ID), not the frontmost window — otherwise the tab lands in whatever
# unrelated window happens to be in front.
#
# agterm realizes terminal surfaces lazily and only while the window actually renders;
# with the display locked/asleep (phone via Remote Control) `session type` fails with
# "session not realized" forever. In that case the dead tab is closed and the same
# setup + claude runs in a detached tmux session instead (`opened-tmux <name>` —
# attach later with `tmux attach -t <name>`).
#
# OUTSIDE agterm (phone / no agtermctl) it's a NO-OP: prints "no-agterm" and exits 0
# so the skill provisions in the current session instead.
#
# Usage:  worktree-open-session.sh <worktree-path> <branch>
# Output (one line): no-agterm | opened-session <id> | opened-tmux <name> | agterm-session-failed
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

wt="${1:?usage: worktree-open-session.sh <worktree-path> <branch>}"
branch="${2:?usage: worktree-open-session.sh <worktree-path> <branch>}"
slug="${wt:t}"   # worktree dir basename == the slug / session name
# Short Remote Control name (ticket first); the agterm sidebar name stays $slug.
rcname="$("$HOME/.config/harness/rc-name.sh" "$slug")"
[[ -n "$rcname" ]] || rcname="$slug"   # helper missing → the old long name, never an empty one

open_tmux_fallback() {
  command -v tmux >/dev/null 2>&1 || { print -- "agterm-session-failed"; exit 1; }
  local tname="$slug" n=2
  while tmux has-session -t "=$tname" 2>/dev/null; do tname="${slug}-$((n++))"; done
  tmux new-session -d -s "$tname" -c "$wt" \
    "$HOME/.config/harness/worktree-setup.sh '${branch}'; claude --remote-control '${rcname}'" \
    || { print -- "agterm-session-failed"; exit 1; }
  print -- "opened-tmux $tname"
  exit 0
}

if [[ -z "${AGTERM_SESSION_ID:-}${AGTERM_ENABLED:-}" ]] || ! command -v agtermctl >/dev/null 2>&1; then
  print -- "no-agterm"; exit 0
fi

# pin to the invoking shell's window/workspace when known
win_args=(); ws_args=(--workspace active)
[[ -n "${AGTERM_WINDOW_ID:-}" ]] && win_args=(--window "$AGTERM_WINDOW_ID")
[[ -n "${AGTERM_WORKSPACE_ID:-}" ]] && ws_args=(--workspace "$AGTERM_WORKSPACE_ID")

sid="$(agtermctl session new --json "${ws_args[@]}" "${win_args[@]}" --cwd "$wt" --name "$slug" 2>/dev/null | jq -r '.result.id // empty')"
if [[ -z "$sid" ]]; then open_tmux_fallback; fi

# selecting nudges agterm to realize the new surface; then type with retries
agtermctl session select --target "$sid" "${win_args[@]}" >/dev/null 2>&1
cmd="~/.config/harness/worktree-setup.sh '${branch}'; claude --remote-control '${rcname}'"
typed=0
for _ in 1 2 3; do
  sleep 2
  if agtermctl session type "$cmd"$'\n' --target "$sid" "${win_args[@]}" >/dev/null 2>&1; then
    typed=1; break
  fi
done

if (( typed )); then
  # Pin the conversation for the next launch (same rule as worktree-new.sh): auto-capture
  # only records a foreground at a clean quit, so a reboot brings the pane back as a bare
  # shell unless the conversation is pinned. The claude wrapper binds the tab's first
  # conversation to the tab's own uuid (lowercase), and rescues a --resume of one that does
  # not exist yet by creating it — so pinning before claude starts is safe.
  agtermctl session restore "claude --resume $(printf '%s' "$sid" | tr '[:upper:]' '[:lower:]') --remote-control '${rcname}'" --target "$sid" "${win_args[@]}" >/dev/null 2>&1 || true
  print -- "opened-session $sid"
  exit 0
fi

# surface never realized (display locked / window not rendering) — drop the dead tab
# and fall back to tmux with a Remote Control session named after the slug
agtermctl session close --target "$sid" "${win_args[@]}" >/dev/null 2>&1
open_tmux_fallback
