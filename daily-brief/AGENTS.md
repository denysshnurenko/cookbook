---
name: daily-brief
description: Generate a structured daily standup brief from your activity across GitHub, Slack and an issue tracker over a day or a range, then post it to Slack as a Canvas with a short linked summary in the channel. Use when the user asks for a daily brief, a standup summary, what they did today/yesterday/this week, after a weekend, or before the daily meeting.
argument-hint: [--date=YYYY-MM-DD | --from=YYYY-MM-DD --to=YYYY-MM-DD | --days=N] [--time-from=HH:MM] [--time-to=HH:MM] [--channel=NAME] [--dry-run]
---

# Daily Brief

Collects your activity from GitHub, Slack and the issue tracker over a local-time window,
groups it by task, sorts it into buckets, and posts a brief to Slack: a **Canvas** with the
detail plus a **short channel message** whose lines deep-link into it.

This file is both the recipe and the skill. To install it, copy it to
`~/.claude/skills/daily-brief/SKILL.md` — the frontmatter above is what makes it a skill.

Everything installation-shaped (channel ids, tracker host, your email, the Keychain item) lives
in `config.json` beside it — start from `config.example.json`.

## Arguments (parse from `$ARGUMENTS`)

| Arg | Default | Notes |
|-----|---------|-------|
| `--date=YYYY-MM-DD` | — | Single day. Sets `--from` and `--to` to the same value |
| `--from=YYYY-MM-DD` | smart (below) | First day of the range, local |
| `--to=YYYY-MM-DD` | smart (below) | Last day, inclusive |
| `--days=N` | — | Range covering the last N days ending yesterday |
| `--time-from=HH:MM` | smart (below) | Start time on the *first* day |
| `--time-to=HH:MM` | smart (below) | End time on the *last* day |
| `--channel=NAME` | `default_channel` from config | Resolved via config first, then search, then DM |
| `--channel-id=ID` | — | Skip resolution entirely. Use for private channels search cannot see |
| `--dry-run` | off | Print the artefacts, post nothing |

### Smart defaults — "since the last standup"

Read `standup_time_kyiv` from `config.json`. The window runs **from the previous standup to
today's**, which catches evening and overnight work *and* this morning's work before the
meeting.

| Today | `--from` | `--to` | `--time-from` / `--time-to` |
|---|---|---|---|
| Tue–Fri | yesterday | today | `<standup_time>` |
| Monday | last Friday | today | `<standup_time>` |
| Sat / Sun | yesterday | today | `<standup_time>` |

Monday implicitly covers the weekend. If the user is catching up after days off, make them pass
`--from` / `--to` / `--days=N` — **do not guess about an absence.** If they say "for today"
mid-day, ask whether they mean today's work-in-progress or the since-last-standup window; the
second is usually what they mean.

## Workflow

### Step 1 — Identify the user

- `gh api user --jq '.login'` → `GH_USER`
- Slack user id: the *current logged-in user's id*, shown in the description of the
  `slack_search_*` tools → `SLACK_USER_ID`
- Tracker user: many trackers have **no whoami tool**, so look yourself up by email — list
  users with `search=<tracker.user_email from config>` and keep the matching row's id and full
  name → `TRACKER_USER_ID`, `TRACKER_FULL_NAME`

If the tracker's MCP server is not connected to this session at all, say so, skip §2.3, and
build the brief from GitHub + Slack.

### Step 2 — Collect

**2.1 GitHub**

```bash
bash <recipe>/collect-github.sh "$GH_USER" "$DATE_FROM" "$DATE_TO" "$TIME_FROM" "$TIME_TO"
```

Returns JSON: `commits`, `actions_runs`, `prs_created`, `prs_merged`, `prs_reviewed`,
`commit_comments`, `pr_review_comments`, `issue_comments`. Set
`DAILY_BRIEF_BASELINE_REPOS="owner/a owner/b"` to also check Actions runs in repos you did not
commit to in this window (a deploy you triggered, a nightly you watch).

**2.2 Slack — what you said.** For each day in the range, search
`from:<@SLACK_USER_ID> on:YYYY-MM-DD`, `sort=timestamp`, `sort_dir=asc`,
`response_format=concise`, `limit=20`, paginating inside the window. Drop hits outside
`[time_from on the first day, time_to on the last]`; days in between run 00:00–23:59. For
ranges of 3+ days prefer one search per day — Slack search returns at most 100 per query. Keep
both top-level messages and your replies.

**2.2b Slack — what is waiting on you.** Same loop, query
`<@SLACK_USER_ID> -from:<@SLACK_USER_ID> on:YYYY-MM-DD` — messages where somebody *else*
@-mentioned you. Then decide per mention whether it still waits:

1. Drop bots, CI and empty pings.
2. For each human mention, read the thread and look for **your reply before `time_to`**.
3. It counts as answered only if the reply is **substantive**. "ок", "гляну", a lone emoji —
   still pending.
4. Anything left goes to the **📨 Waiting on me** bucket with channel, author, the gist of the
   ask, and the permalink.

Two caveats worth stating in the brief rather than hiding: this catches only direct `<@id>`
mentions — `@channel`, `@here` and user-group pings never come back from search; and a reply
you posted *after* `time_to` still counts as pending **for this window**, so mark it "answered
just after cutoff" rather than dropping it (otherwise it reappears tomorrow as if ignored).

**2.3 Tracker — issues you touched, and your comments.**

⚠️ **Read this before implementing.** A tracker's MCP surface usually has **no per-user
activity log and no server-side assignee / updated-at / date filters** — so you cannot ask
"changes by user X between A and B". This step therefore *approximates* your activity as
**issues currently assigned to you whose `updatedAt` falls in the window, plus your comments**.
It over-selects (any field edit by anyone bumps `updatedAt`) and cannot attribute a status
change to you. So treat **GitHub and Slack as the real "what I did"**, and the tracker as
"current state of my board". Say so if the user asks how the numbers were derived.

1. **Issues** — list issues ordered newest-created, `limit=100`, scoped by your team or project
   so you do not page the whole account. Keep a row when `updatedAt` ∈ window **and**
   `TRACKER_FULL_NAME` ∈ its assignees; also keep rows created in the window that are yours.
2. **Detail** — for each kept issue, and for any issue number surfaced from GitHub or Slack,
   fetch the full issue: status, assignees, project, sprint, description, comment count.
3. **Your comments** — per candidate issue, list comments and keep those authored by
   `TRACKER_USER_ID` inside the window. There is rarely a "my comments" query.
4. **Requests / triage queue** — if the tracker has an inbox separate from issues, walk it the
   same way.

**Status → bucket**: a completed category → ✅ Done. In-progress or not-started but assigned to
you → 📅 Plans. Any status naming a block ("Fix Needed", "Blocked") → ⚠️ Blockers.

**Priority → colour**: urgent/critical → 🔴, high/medium → 🟡, low/none → 🟢. Anything
prod-affecting stays 🔴 whatever the field says.

**Links**: reference items as `#<number> <name>` linking to `<tracker.web>/issues/<number>` —
the human URL uses the issue *number*, not the machine id.

### Step 3 — Cross-reference

```bash
TRACKER_HOST=tracker.example.com python3 <recipe>/crossref.py /tmp/combined.json
```

Groups every artefact under the task id it belongs to and returns
`{task_id: {commits, prs, tracker_issues, tracker_comments, …}}` plus an `unmatched` bucket.
Ids are extracted from issue links, machine ids, commit messages
(`feat|fix|chore|refactor(<id>/…)`), branch names and PR titles.

It deliberately matches **two id spaces at once** — the current tracker's numbers and legacy
10-digit ids — because during a tracker migration old commits keep pointing at the old system
for months. Items in different id spaces will not line up unless someone recorded the mapping:
**note the gap, do not force a match.**

### Step 4 — Bucket and prioritise

- **✅ Done** — merged PRs, issues in a completed status, deployed commits with green Actions,
  reviews finished
- **⚠️ Blockers** — failed deploys, explicit "blocker"/"urgent"/"broken" in Slack, things
  waiting on other people, issues in a Fix-Needed-like status
- **📅 Plans** — open PRs, issues assigned but not done, promises you made in Slack ("I'll do
  it", "still left to"), TODOs
- **📨 Waiting on me** — the §2.2b mentions you never substantively answered
- **📁 Other** — housekeeping, small admin

🔴 prod-affecting, explicit urgency, failed CI, blockers · 🟡 dev/stage merges, reviews,
architectural discussion, ordinary unanswered mentions · 🟢 housekeeping, minor fixes.

**Omit any empty bucket entirely** — a heading with nothing under it teaches the reader to skim
past headings.

### Step 5 — Canvas

- Title: `Daily Brief — <name> · D Month YYYY`. Put the name in: a canvas gets shared.
- First block, a callout with author, period and generation time. `![](@SLACK_USER_ID)` renders
  as an inline user card.
- `## 📊 Summary` with a counts table (bucket × priority).
- Section order: ✅ → ⚠️ → 📨 → 📅 → 📁.
- One `### <emoji> [<priority>] <title>` per item, details underneath, with every relevant link
  — PR, commit, issue, Slack permalink.
- Plans use checklist syntax `- [ ] …` so they can be ticked in place.

Create the canvas, then read it back to get its `section_id_mapping`, and map each heading to
its section id — those ids are what the channel message links to.

### Step 6 — The short channel message

```
📋 *Daily Brief — D Month* · HH:MM → HH:MM
<canvas_url>

📊 ✅ <N> · ⚠️ <N> · 📨 <N> · 📅 <N>

*✅ Done*
• 🔴 [<title>](<canvas_url>?focus_section_id=<section_id>) — `[high]`
…

_💡 close the canvas before clicking — deep links only fire on a cold open._
```

Write it in **standard markdown** (`[text](url)`, `**bold**`). `post-as-bot.py` converts to
Slack mrkdwn on the way out; pre-converting would double-escape. Markdown is also what the MCP
fallback and `--dry-run` expect, so one format serves all three paths.

### Step 6b — Post it as a bot, not as yourself

```bash
python3 <recipe>/post-as-bot.py "<the Step 6 message>"
```

**Why a bot.** Slack raises **no notification and no unread badge for your own messages**. If
the brief goes to a channel you are the only member of, posting it under your own name means it
arrives already-read — which is exactly how briefs go unnoticed. From a bot identity it
notifies normally. The canvas is still created by your user token; only the sender of the final
message changes.

`--show` prints the converted text and sends nothing (eyeball the links first). `--update <ts>`
rewrites a message already posted — the right fix for a brief that landed with a formatting
bug, because it repairs the existing permalink instead of adding a second notification.

**This helper is deliberately not fail-soft** — it *is* the delivery. A silent `exit 0` would
look like a posted brief while nothing landed. If it exits non-zero, do **not** report success:
fall back to the MCP `slack_send_message` (posts under the user's name, so it will not notify)
and say plainly that the bot post failed and why.

Skip this step on `--dry-run`.

### Step 7 — Resolve the destination

1. `config.json` `channels` map — if the name is there, use the id and skip searching.
2. Otherwise search channels by name; cache the id back into `config.json`.
3. Otherwise DM yourself (`SLACK_USER_ID` as the channel id).

**Private-channel caveat**: channel search does not return private channels the Slack app is
not a member of, even ones *you* are in. Ask for the id (it is in the channel URL,
`…/archives/<ID>`) and add it to the config once.

### Step 8 — Dry run

With `--dry-run`, call no canvas and no send. Print the canvas markdown, print the channel
message, and state which channel would have been used.

## Notes

- **Timezones**: the helpers convert local→UTC. Trust them rather than re-deriving offsets, and
  remember the offset changes with daylight saving.
- **Deep-link quirk**: `?focus_section_id=…` only scrolls on the *first* open of a canvas.
  Clicking again while it is open does nothing — that is why the footer tip exists.
- **Section ids** are stable per canvas content; they invalidate only on heavy edits.
- **Empty categories** are omitted, not rendered empty.

## Sanity checks before posting

- Do the task ids in commits match issues that actually moved? If not, flag it — a status
  update was probably skipped.
- Are things you promised in Slack present in Plans? A promise made yesterday and not done
  today should go up in priority, not quietly disappear.
- Did §2.2b actually run? Every direct mention must end up either answered-in-window or in
  📨 Waiting on me. Do not drop a mention because its *topic* appears elsewhere — the reply may
  still be outstanding.
- Do the deep links resolve? Check the section ids in the URLs against the mapping you read
  back.
