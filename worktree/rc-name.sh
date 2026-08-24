#!/usr/bin/env zsh
# harness rc-name: turn a branch slug into a SHORT Remote Control session name.
#
# Why (2026-08-24): Remote Control is already ON for every session
# (`remoteControlAtStartup: true` in ~/.claude/settings.json), so claude's
# `--remote-control` flag does NOT enable anything — it only NAMES the session.
# Given no name, claude auto-generates one prefixed with the machine hostname, so
# every session in the mobile list looks the same.
#
# The worktree scripts used to pass the full branch slug. That is up to ~56 chars and
# puts the only distinguishing part — the ticket id — in the MIDDLE, after feat-/fix-,
# so a truncated mobile list reads 'feat-…', 'fix-…', 'feat-…'. This puts the ticket
# FIRST and keeps a few meaningful words:
#
#   feat-<id>-change-url-of-the-product-to-new-place  ->  <id>-product-new-place
#   fix-<id>-as-a-manager-i-can-pick-contact-request  ->  <id>-pick-contact-request
#
# The agterm sidebar name is NOT affected — that stays the full branch slug.
#
# The id token is `dt` + 2 or more digits — the branch convention in use since 2026-07-31
# (`<type>/dt<number>-<kebab>`). solidtime/st `parse_ticket_num` also still lists the retired
# `us|bug|issue|task` tokens for branches that predate it; there are none left and none coming,
# so this file only needs `dt`. A branch with no id token falls back to its own words minus
# the type prefix.
#
# Callers: worktree-new.sh, worktree-open-session.sh. Both call this file rather than
# copying the logic — duplicated blocks in this harness have drifted before.
#
# Usage:  rc-name.sh <branch-slug>   →  prints the RC name on stdout
set -uo pipefail

slug="${1:?usage: rc-name.sh <branch-slug>}"

s="${slug:l}"
s="${s//[^a-z0-9]/-}"
words=(${(s:-:)s})

# words carrying no meaning in a ticket title ('as a manager i can pick …')
stop=(a an the of to in on for and or with from at by as is are be been it its
      i we us my me you your can could do does did not no that this these those
      so if all any some when while into onto over under out up down)

ticket=""
rest=()
for w in $words; do
  if [[ -z "$ticket" && "$w" =~ '^dt[0-9]{2,}$' ]]; then
    ticket="$w"; continue
  fi
  [[ -n "$ticket" ]] && rest+=$w
done

if [[ -z "$ticket" ]]; then
  rest=($words)
  [[ "${rest[1]:-}" == (feat|fix|chore|refactor|docs|test|hotfix|bugfix|perf|build|ci|style) ]] \
    && rest=(${rest[2,-1]})
fi

keep=()
for w in $rest; do
  (( ${stop[(Ie)$w]} )) && continue
  keep+=$w
done
(( ${#keep} == 0 )) && keep=($rest)          # title was ALL stop-words: keep them
(( ${#keep} > 3 )) && keep=(${keep[-3,-1]})  # the tail is usually the object

if [[ -n "$ticket" ]]; then
  name="$ticket${keep:+-${(j:-:)keep}}"
else
  name="${(j:-:)keep}"
fi

name="${name#-}"; name="${name%-}"
[[ -z "$name" ]] && name="$slug"             # never print nothing
(( ${#name} > 40 )) && name="${name[1,40]%-*}"
print -r -- "$name"
