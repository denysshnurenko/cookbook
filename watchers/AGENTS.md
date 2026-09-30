# watchers — agent contract

`watch-lane.py` is a polling daemon that types ONE prompt line into the agterm session that owns
a piece of work. Read this before adding a lane or calling it.

## Invariants (do not break)

1. **Never type into a session without the three gates**: `provider == "claude"` (foreground
   argv), `status != "active"` (the agent-status glyph set by Claude Code hooks), and
   `typed_text(sid) == ""` (the space-and-backspace probe — a plain `session text` read mistakes
   Claude Code's ghost suggestion for typed text).
2. **One bracketed paste, then a separate Return after `WATCH_SETTLE`.** Character-typed prompts
   race their own Return and submit a fragment.
3. **Verify, then stamp.** `still_in_box()` after `WATCH_VERIFY`; a stamp is written only after a
   verified send, so an undelivered event returns on the next pass. A stamp key names the EVENT
   (event timestamp, head sha), never just the PR — the same PR can speak again.
4. **Read the pane you write to** (`session text --pane left`). Never the visible pane.
5. **A lane fault never ends the loop**: catch everything inside `once()`; log; continue.
6. **The prompt is one short line** naming the URL and what to do; the receiving session has its
   own skills for the rest. A long payload is fine in a bracketed paste, but the line is what
   he reads in a queue.

## Adding a lane

A lane is `lane_<name>(prs, rows)`: iterate the events of your source, find the session with
`session_for_branch(rows, branch)` (or by ticket / cwd), build the line, call
`deliver(row, text, stamp_path, tag)`. Stamps live under `WATCH_STATE/delivered/`. Put the
source poll in `once()` next to `my_open_prs()`; keep polls cheap (seconds) and model-free.

## Environment

| var | default | meaning |
|---|---|---|
| `WATCH_REPOS` | — (required) | `owner/name[,owner/name]` |
| `WATCH_GH_LOGIN` | — (required) | your GitHub login: your own reviews/comments end the "ball with me" window |
| `WATCH_REVIEWER` | `` | login whose APPROVED is required; empty = every requested reviewer |
| `WATCH_BOTS` | `` | logins never counted as a colleague |
| `WATCH_SELF_LABEL` / `WATCH_WAIVE_LABEL` | `self-reviewed` / `no-human-review` | the two labels the gate reads |
| `WATCH_GATE_CMD` | `` | shell command run with `PR`, `BRANCH`, `REPO` in env; exit 0 = external gate passed |
| `WATCH_TICK` | `300` | seconds between passes |
| `WATCH_STATE` | `~/.cache/watch-lane` | log + stamps |
| `WATCH_GH` / `WATCH_AGTERMCTL` | `gh` / `agtermctl` | binaries (absolute paths when run from launchd) |

## Exit and failure rules

- Missing `WATCH_REPOS`/`WATCH_GH_LOGIN` → exit 1 with the message; nothing else is fatal.
- `gh` failure → that pass sees no PRs; logged.
- No agterm tree → the pass does nothing; logged.
- `--dry-run` never types and never stamps; it prints the line it would have typed.
