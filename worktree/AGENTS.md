# Worktree toolkit — agent cookbook

Operating guide for an AI agent driving this harness's git-worktree flow. Two
operations: **NEW** (create + provision a per-branch worktree) and **ARCHIVE**
(tear one down). Written to be loaded as agent context (skill body, AGENTS.md
include, or pasted reference) — a human quick-start lives in `README.md` next to
this file.

## Model

- One branch = one worktree, a **sibling** of the main checkout:
  `<parent>/<repo>.worktrees/<slug>`, where `slug` = branch name with `/` → `-`.
  Example: `~/dev/hopecloud` + branch `feat/dt123-thing` →
  `~/dev/hopecloud.worktrees/feat-dt123-thing`.
- Each worktree gets an isolated environment — own Postgres container, port range,
  Caddy fragment — when the repo ships `infra/worktree/setup.sh` /
  `infra/worktree/archive.sh` (hopecloud does). Repos without them get a minimal
  fallback: real `.env*` files symlinked from the main checkout + dependency install.
- Helper scripts in `~/.config/harness/` do the real work. **Call them; never
  reimplement their logic inline.** All four core scripts are TTY-free — they work
  from any agent context, including Remote Control / phone.
- If the `worktree` / `worktree-archive` skills are installed under
  `~/.claude/skills/`, prefer invoking those — they encode this same procedure with
  the user-interaction steps built in. This cookbook makes an agent WITHOUT those
  skills able to run the flow with Bash alone.

## Script contracts

| Script | Args | Output contract |
|---|---|---|
| `worktree-create.sh` | `<branch> [base]` | stdout: the new worktree's **absolute path** (last line — capture it); progress on stderr. Non-zero exit = **nothing was created**: surface stderr, stop. |
| `worktree-setup.sh` | `<branch>` | Run with **cwd inside the worktree**. Human-readable progress; non-zero exit = provisioning failed but worktree+DB exist (see Failure rules). |
| `worktree-open-session.sh` | `<wt-path> <branch>` | ONE line on stdout: `no-agterm` \| `opened-session <id>` \| `opened-tmux <name>` \| `agterm-session-failed`. Exit 0 except on total failure. |
| `worktree-archive.sh` | `<wt-path>` | stdout: `ARCHIVED slug=<slug> branch=<orig> remote=<yes\|no> drifted=<branch-or-empty>`; progress on stderr. Non-zero exit = teardown aborted (nothing irreversible happened past the reported step). |

`base` semantics in create: default `master`; literal `.` or `HEAD` = the repo's
current branch. base == current branch → branches off the **local** ref (keeps
unpushed work); anything else → `git fetch origin <base>` first and branches off
`origin/<base>` (falls back to the local ref if the fetch fails).

What create does besides `git worktree add` (so you don't redo it):

- records the branch in the worktree's git admin dir as `harness-original-branch`
  (ARCHIVE's deletion target — survives HEAD drift);
- copies `.ralphex/` minus `progress/` (git-ignored, so `worktree add` skips it);
- copies `.claude/settings.local.json` — the checkout's approved permissions.
  **Copy, never symlink**: Claude Code rewrites this file via write-temp-then-rename,
  which would silently replace a symlink with a detached regular file;
- (optional integration) binds + starts the Solidtime timer for the branch's ticket
  when `~/.config/harness/solidtime/st` is installed; silently self-skips otherwise.

## Procedure: NEW

1. **Confirm the repo.** `git -C "$PWD" rev-parse --show-toplevel`. On failure tell
   the user to run from inside the target repo and STOP.
2. **Gather branch + base.** From the user's message or by asking — branch first
   (required), then base (default `master`). Exactly these two questions.
3. **Create:**
   ```sh
   wt="$(~/.config/harness/worktree-create.sh '<branch>' '<base>')"
   ```
   Non-zero exit → report stderr (branch/worktree already exists, bad base, not a
   repo) and STOP — nothing was created.
4. **Solidtime (SKIP unless installed).** If stderr printed a
   `⏱ NO SOLIDTIME TASK` block, follow the commands inside it: fetch the real issue
   title from the tracker (the derived title in the block is lossy — a branch slug
   drops words), ASK the user to confirm title + project, then `st create-task` →
   `st bind` → `st start … --unless-sticky`. User declines → skip, not an error.
5. **Open a session / provision:**
   ```sh
   ~/.config/harness/worktree-open-session.sh "$wt" '<branch>'
   ```
   Act on the single output line:
   - `opened-session <id>` — a new agterm tab is ALREADY running provisioning +
     `claude --remote-control '<slug>'`. **Do not provision again.** Report and done.
   - `opened-tmux <name>` — display was locked (typical for phone / Remote Control);
     same provisioning + claude is running in a detached tmux session. **Do not
     provision again.** Tell the user: it appears in Remote Control as `<name>` after
     setup (several minutes); at the Mac, `tmux attach -t <name>`.
   - `no-agterm` — provision here yourself:
     ```sh
     cd "$wt" && ~/.config/harness/worktree-setup.sh '<branch>'
     ```
     Takes minutes (install, DB) — wait for it; don't declare success early.
   - `agterm-session-failed` — same as `no-agterm`, and mention the fallback.
6. **Report:** worktree path, branch, base, and which of the outcomes above happened.

## Procedure: ARCHIVE (DESTRUCTIVE — confirmation is mandatory)

Deletes: the DB container + volume + Caddy fragment, the worktree directory
(**including uncommitted work**), the local branch, and optionally the remote branch.

1. **Pick the target.** `git -C "$PWD" rev-parse --show-toplevel` +
   `git worktree list`. Current dir is a non-main worktree → that's the target.
   Main checkout or not a worktree → list the non-main worktrees and ASK. **Never
   guess, never target the main checkout** (first line of `worktree list`).
2. **Inspect for data loss** and surface it before asking anything:
   - `git -C "$wt" status --porcelain` — non-empty = uncommitted changes will be lost;
   - `git -C "$wt" log --oneline @{upstream}..HEAD` — unpushed commits (or "no upstream");
   - which branch will be deleted and whether `origin/<branch>` exists.
3. **Confirm.** Present exactly what will be destroyed, then offer:
   **Full teardown** (also delete `origin/<branch>`) / **Keep remote** / **Cancel**.
   Proceed ONLY on an explicit Full or Keep choice.
4. **Run:**
   ```sh
   ~/.config/harness/worktree-archive.sh "$wt"
   ```
   Parse the `ARCHIVED …` stdout line. Non-zero exit → report why and STOP.
   `drifted=<x>` non-empty → tell the user HEAD had drifted to `<x>`; only the
   original branch was deleted, `<x>` was left untouched.
5. **Remote branch** — only if the user chose Full AND the line says `remote=yes`:
   ```sh
   git -C '<main-checkout>' push origin --delete '<branch>'
   ```
   "remote ref does not exist" = already gone, not an error.
6. **agterm session cleanup** — only when agterm is reachable (`AGTERM_SESSION_ID`
   set or `agtermctl tree --json` responds). Find sessions whose `cwd` is the
   archived dir or inside it; `agtermctl session close --target <id>` each — EXCEPT
   your own (`$AGTERM_SESSION_ID`): closing it kills this conversation, so print the
   final report FIRST and close your own session as the very last action (or tell
   the user to cmd+w it).
7. **Report** everything torn down, warnings included.

## Invariants — never violate, never "fix"

- The scripts refuse the **main checkout** and never delete **master/dev**. These are
  guards, not bugs — do not work around them.
- Branch deletion targets the **recorded original branch**, not current HEAD. A
  drifted HEAD is reported and left alone (it may be a release branch or someone
  else's work). Never delete the drifted branch on your own initiative.
- Docker teardown is keyed by the **worktree directory name** (fixed at creation),
  not the current branch — that's deliberate; don't "correct" it.
- DB archive steps are best-effort/idempotent ("already gone" is fine);
  `git worktree remove` is NOT — if it fails, teardown aborts with branches intact.
- Copy — never symlink — `.claude/settings.local.json` into a worktree.
- Archive without an explicit user confirmation in this conversation is forbidden,
  even when the request sounded certain.

## Failure rules

| Situation | Rule |
|---|---|
| `worktree-create.sh` non-zero | Nothing was created. Report stderr, stop. Don't retry with tweaked names on your own. |
| `worktree-setup.sh` non-zero | Worktree + DB **exist**. Report the error; fix the cause if asked, then re-run `worktree-setup.sh '<branch>'` in the worktree. Don't archive as "cleanup". |
| env sync dies on IAM / Secret Manager | Add the app to `~/.config/harness/env-skip` (one name per line). If setup warned the CLI predates the skip feature (PR #948), rebase the worktree onto master first. |
| `worktree-archive.sh` non-zero | Teardown aborted; state is as reported on stderr. Surface it, stop. |
| Stale worktree dir, branch gone | `git worktree list` to see if git still tracks it; if not: `git worktree prune` + remove the dir — but confirm with the user first (dir contents die). |

## Installing on a new machine

The scripts ship NEXT TO this file (public mirror: github.com/denysshnurenko/cookbook,
`worktree/`). Minimal set (no agterm): copy `worktree-create.sh`,
`worktree-setup.sh`, `worktree-archive.sh`, `worktree-open-session.sh` (no-op
outside agterm, but the procedure calls it) into `~/.config/harness/` and make them
executable. Paths are hardcoded to `~/.config/harness/` — keep the layout or edit
every reference. Dependencies: zsh, git, jq; docker CLI for teardown; optional: tmux
(fallback), pnpm/yarn/npm (provisioning), agterm, solidtime (self-skips when
absent). This file itself is the agent integration: load it as a skill or context.
agterm hotkey setup and the human quick-start are in `README.md`.
