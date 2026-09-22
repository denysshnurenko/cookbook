---
name: slack-user-token
description: Post, edit or upload to Slack as the user over plain HTTP with their user token (xoxp) from the Keychain — no MCP. Use when a message must be edited after it is sent, a file must go into a thread, the Slack MCP connector is unavailable (headless runs, cron), or the user says to send "through the token".
---

# slack-user-token

`slack-token.py` (next to this file) is the whole tool: stdlib python3, one Slack Web API call
per action, the token read from the macOS Keychain item `slack-user-token` (account `$USER`) or
`$SLACK_USER_TOKEN`. Everything it posts is posted **as the user** — treat every `--post`,
`--update` and `--upload` as sending a message on their behalf: only when they asked for it.

## Contract

| command | needs | prints | scope |
|---|---|---|---|
| `--check` | — | who, workspace, granted scopes | any |
| `--post --channel ID --file F [--thread TS] [--plate TEXT]` | text file | permalink | `chat:write` |
| `--update --channel ID --ts TS --file F [--plate TEXT]` | text file | permalink | `chat:write` |
| `--upload --channel ID --file F [--thread TS] [--title T]` | any file | file permalink | `files:write` |

Exit: `0` ok · `1` Slack refused (reason on stderr) · `2` bad arguments or no token ·
`3` the token lacks a scope — tell the user which one; they add it in the app's **OAuth &
Permissions → User Token Scopes**, reinstall, and re-store the token. Never work around a `3`.

- `--channel` takes a channel id (`C…`) or a DM id (`D…`). `--post` also takes a **person's**
  id (`U…`) and posts into the DM with them; `--update` does not — use the `D…` id from the
  post's permalink. Resolve a name to an id before calling.
- The file is **standard Markdown**, not Slack mrkdwn: `**bold**`, `[text](url)`, `` `code` ``.
- `--update` replaces the WHOLE message, blocks included: pass the full new text, and pass
  `--plate` again if the message had one.
- A thread `TS` is the ts of the thread's ROOT message (`p1726412345678900` in a permalink →
  `1726412345.678900`).

## Invariants

- **Never put a bot/app mention (`<@U…>`) in the message text** — Slack then offers to add
  that bot to the conversation. A mention belongs in `--plate` (a `context` block), which
  renders as a small grey line and triggers nothing.
- **A token edit is invisible**: `chat.update` sets `edited` in the API, but the Slack UI shows
  no «(edited)» label. Say so when you edit something a person has already read — they will not
  see it changed.
- **Rate**: `chat.update` is Tier 3, ~50/min. A live-updating message at one edit per ~1.2 s
  ran 8.5 minutes clean; go faster and expect `ratelimited` (the script waits once, then
  fails).
- **Never print or log the token.** `--check` shows who it belongs to, not its value.
