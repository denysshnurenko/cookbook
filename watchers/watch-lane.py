#!/usr/bin/env python3
"""watch-lane — a watcher that polls GitHub and speaks into the agterm session that owns the work.

The pattern behind every lane of my dispatcher, in one file with two lanes that need only `gh`:

  pr_events   a colleague reviewed or commented on MY open PR after my last move
              → one line into the PR's session: read it, list the remarks, change nothing yet
  merge_gate  my PR satisfies every merge condition (reviewer approve or a waiver label,
              my self-review label, green checks, mergeable, an optional external gate command)
              → one line into the PR's session: land it

  poll (gh, a few seconds, no model)  →  json cache  →  find the session by branch
  →  three gates (claude in the foreground · not mid-turn · empty input box)
  →  bracketed paste + a separate Return  →  read the box back  →  stamp the event

Nothing here reads a ticket tracker or Slack; that is what `WATCH_GATE_CMD` is for (a command
that exits 0 when your tracker says the PR may land — see README). Python 3.9, stdlib only.

USAGE
  watch-lane.py                # loop every WATCH_TICK seconds (default 300)
  watch-lane.py --once         # one pass
  watch-lane.py --once --dry-run   # one pass, print what would be typed, type nothing
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

GH = os.environ.get("WATCH_GH", "gh")
AGTERMCTL = os.environ.get("WATCH_AGTERMCTL", "agtermctl")
REPOS = [r for r in os.environ.get("WATCH_REPOS", "").split(",") if r]          # owner/name,…
ME = os.environ.get("WATCH_GH_LOGIN", "")                                      # your GitHub login
REVIEWER = os.environ.get("WATCH_REVIEWER", "")                                # login whose approve counts
BOTS = {b for b in os.environ.get("WATCH_BOTS", "").split(",") if b}           # logins that never count
LABEL_SELF = os.environ.get("WATCH_SELF_LABEL", "self-reviewed")
LABEL_WAIVE = os.environ.get("WATCH_WAIVE_LABEL", "no-human-review")
GATE_CMD = os.environ.get("WATCH_GATE_CMD", "")   # optional: run with PR number + branch; exit 0 = may land
TICK = int(os.environ.get("WATCH_TICK", "300"))
STATE = Path(os.environ.get("WATCH_STATE", Path.home() / ".cache" / "watch-lane"))
SETTLE = float(os.environ.get("WATCH_SETTLE", "0.6"))     # between the paste and the Return
VERIFY = float(os.environ.get("WATCH_VERIFY", "1.5"))     # before reading the box back
GREEN = {"SUCCESS", "NEUTRAL", "SKIPPED"}
DRY = "--dry-run" in sys.argv


def log(msg: str) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "watch-lane.log").open("a", encoding="utf-8") as fh:
        fh.write(f"{time.strftime('%F %T')} {msg}\n")
    if DRY or "--once" in sys.argv:
        print(msg)


# ── agterm ─────────────────────────────────────────────────────────────────────────────────────

def ctl(*args: str, timeout: int = 10) -> str:
    """agtermctl, '' on any failure — a watcher must survive anything the terminal does."""
    try:
        return subprocess.run([AGTERMCTL, *args], capture_output=True, text=True,
                              timeout=timeout).stdout
    except Exception as exc:  # noqa: BLE001
        log(f"agtermctl {' '.join(args)} failed: {exc}")
        return ""


def sessions() -> list:
    """Every session of the frontmost window: id, name, cwd, status, foreground argv."""
    try:
        tree = json.loads(ctl("tree", "--json"))["result"]["tree"]
    except Exception:  # noqa: BLE001
        return []
    out = []
    for ws in tree.get("workspaces", []):
        for s in ws.get("sessions", []):
            fg = s.get("foreground") or []
            out.append({"id": s.get("id", ""), "name": s.get("name", ""), "cwd": s.get("cwd", ""),
                        "status": s.get("status") or "idle", "provider": fg[0] if fg else ""})
    return out


def session_for_branch(rows: list, branch: str):
    """The session whose name or cwd carries the branch — or its worktree slug (`/` → `-`)."""
    slug = branch.replace("/", "-")
    for r in rows:
        hay = f"{r['name']} {r['cwd']}"
        if branch and (branch in hay or slug in hay):
            return r
    return None


def composer_text(sid: str):
    """What sits in the session's input box, None when unreadable. `session text` returns the
    whole screen; the box is the region between the last two horizontal rules agterm draws.
    Read the LEFT pane — the one `session type` writes to — never "the visible pane"."""
    buf = ctl("session", "text", "--pane", "left", "--target", sid)
    if not buf.strip():
        return None
    lines = buf.splitlines()
    rules = [i for i, ln in enumerate(lines) if ln.strip().startswith("─")]
    region = lines[rules[-2] + 1:rules[-1]] if len(rules) >= 2 else lines[-8:]
    return " ".join(region).replace("❯", "").strip()


def typed_text(sid: str) -> str:
    """Text a HUMAN typed, as opposed to Claude Code's ghost suggestion, which `session text`
    returns exactly like typed text. Typing REPLACES a suggestion but APPENDS to real text: type
    one space, read again, Backspace it away. Unreadable counts as "there is text"."""
    before = composer_text(sid)
    if not before:
        return ""
    ctl("session", "type", " ", "--target", sid, "--pane", "left")
    time.sleep(SETTLE)
    after = composer_text(sid)
    ctl("session", "type", "\x7f", "--target", sid, "--pane", "left")
    if after is None:
        return before
    return before if " ".join(after.split()) == " ".join(before.split()) else ""


def still_in_box(sid: str, sent: str) -> bool:
    """Did OUR prompt fail to submit? Only our own text still sitting there is a failure: a
    suggestion rendered after a successful send is not, and Claude Code's "queued message" note
    (typed while the agent was mid-turn) means it WILL be processed."""
    left = composer_text(sid)
    if not left:
        return False
    if "queued message" in left.lower() or "pasted text" in left.lower():
        return "pasted text" in left.lower()
    return " ".join(sent.split())[:80] in " ".join(left.split())


def deliver(row: dict, text: str, stamp: Path, tag: str) -> bool:
    """The send contract. Returns True when the line was typed AND verified; the stamp is
    written only then, so an undelivered event comes back on the next pass."""
    if stamp.exists():
        return False
    why = ""
    if row["provider"] != "claude":
        why = "no claude in the foreground"
    elif row["status"] == "active":
        why = "agent is mid-turn"
    elif typed_text(row["id"]):
        why = "something is already typed in the prompt"
    if why:
        log(f"{tag}: waiting — {why}")
        return False
    if DRY:
        log(f"{tag}: WOULD type into {row['name']}: {text}")
        return False
    # One bracketed paste (newlines are text, length stops mattering), then a SEPARATE Return
    # after a settle: typed character by character, a prompt races its own Return and submits a
    # fragment.
    ctl("session", "type", f"\x1b[200~{text}\x1b[201~", "--target", row["id"])
    time.sleep(SETTLE)
    ctl("session", "type", "\n", "--target", row["id"])
    time.sleep(VERIFY)
    if still_in_box(row["id"], text):
        log(f"{tag}: send FAILED, text still in the box — retrying next pass")
        return False
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(f"{time.strftime('%FT%T')}\nsession={row['id']}\n", encoding="utf-8")
    ctl("notify", f"{tag} → {row['name']}", "--title", "watch-lane", "--target", row["id"])
    log(f"{tag}: handed to {row['name']}")
    return True


# ── GitHub ─────────────────────────────────────────────────────────────────────────────────────

def gh_json(*args: str, timeout: int = 60):
    try:
        out = subprocess.run([GH, *args], capture_output=True, text=True, timeout=timeout)
        return json.loads(out.stdout or "null")
    except Exception as exc:  # noqa: BLE001
        log(f"gh {' '.join(args[:3])} failed: {exc}")
        return None


def my_open_prs() -> list:
    prs = []
    for repo in REPOS:
        rows = gh_json("pr", "list", "--repo", repo, "--author", "@me", "--state", "open",
                       "--limit", "30", "--json",
                       "number,title,headRefName,headRefOid,baseRefName,isDraft,labels,reviews,"
                       "reviewRequests,comments,commits,statusCheckRollup,mergeable,url") or []
        for pr in rows:
            if not pr.get("isDraft"):
                pr["repo"] = repo
                prs.append(pr)
    return prs


def human(login: str) -> bool:
    return bool(login) and login != ME and login not in BOTS and not login.endswith("[bot]")


def own_pr_latest(pr: dict) -> tuple:
    """(at, who, state, body) of the newest thing a colleague did on MY PR after my last move —
    my last commit, review or comment — or ("", "", "", "") when the ball is not with me."""
    commits = pr.get("commits") or []
    my_last = (commits[-1].get("committedDate") or "") if commits else ""
    events = []
    for rv in pr.get("reviews") or []:
        who, at = (rv.get("author") or {}).get("login") or "", rv.get("submittedAt") or ""
        if who == ME:
            my_last = max(my_last, at)
        elif human(who):
            events.append((at, who, rv.get("state") or "COMMENTED", rv.get("body") or ""))
    for c in pr.get("comments") or []:
        who, at = (c.get("author") or {}).get("login") or "", c.get("createdAt") or ""
        if who == ME:
            my_last = max(my_last, at)
        elif human(who):
            events.append((at, who, "COMMENT", c.get("body") or ""))
    after = [e for e in events if e[0] > my_last]
    return max(after) if after else ("", "", "", "")


def latest_reviews(pr: dict) -> dict:
    """login → that person's newest review state; a later COMMENTED does not undo an APPROVED."""
    out = {}
    for rv in sorted(pr.get("reviews") or [], key=lambda x: x.get("submittedAt") or ""):
        who, state = (rv.get("author") or {}).get("login") or "", rv.get("state") or ""
        if not human(who):
            continue
        if state in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            out[who] = state
        else:
            out.setdefault(who, state)
    return out


def merge_blockers(pr: dict) -> list:
    """Why this PR may not land yet — empty means it may. Pure; see the README for the rules."""
    blockers = []
    labels = {(l.get("name") or "") for l in pr.get("labels") or []}
    states = latest_reviews(pr)
    changes = [w for w, s in states.items() if s == "CHANGES_REQUESTED"]
    if changes:
        blockers.append(f"changes requested by {', '.join(changes)}")
    elif LABEL_WAIVE in labels:
        pass
    elif REVIEWER:
        if states.get(REVIEWER) != "APPROVED":
            blockers.append(f"no approve from {REVIEWER}")
    else:
        asked = [(r.get("login") or "") for r in pr.get("reviewRequests") or []]
        missing = [w for w in asked if states.get(w) != "APPROVED"]
        if missing:
            blockers.append(f"no approve from {', '.join(missing)}")
    if LABEL_SELF not in labels:
        blockers.append(f"no {LABEL_SELF} label")
    checks = pr.get("statusCheckRollup") or []
    red = [(c.get("name") or c.get("context") or "?") for c in checks
           if (c.get("conclusion") or c.get("state") or "") not in GREEN]
    if not checks:
        blockers.append("no checks yet")
    elif red:
        blockers.append(f"checks: {', '.join(red)}")
    if pr.get("mergeable") != "MERGEABLE":
        blockers.append(f"mergeable: {pr.get('mergeable') or 'unknown'}")
    if GATE_CMD and not blockers:
        rc = subprocess.run(GATE_CMD, shell=True, env={**os.environ, "PR": str(pr["number"]),
                            "BRANCH": pr.get("headRefName") or "", "REPO": pr["repo"]},
                            capture_output=True, text=True, timeout=120)
        if rc.returncode != 0:
            blockers.append(f"gate command: {(rc.stdout or rc.stderr).strip()[:80] or 'not yet'}")
    return blockers


# ── lanes ──────────────────────────────────────────────────────────────────────────────────────

def lane_pr_events(prs: list, rows: list) -> None:
    for pr in prs:
        at, who, state, body = own_pr_latest(pr)
        if not who:
            continue
        r = session_for_branch(rows, pr.get("headRefName") or "")
        tag = f"{pr['repo']}#{pr['number']}"
        if not r:
            log(f"{tag}: {state.lower()} by {who} — no session on its branch")
            continue
        did = {"APPROVED": "approved", "CHANGES_REQUESTED": "requested changes",
               "COMMENT": "commented"}.get(state, "left a review comment")
        said = f': "{" ".join(body.split())[:120]}"' if body else ""
        text = (f"On your PR #{pr['number']} {who} {did}{said}. Open {pr.get('url')} , read the "
                f"whole review (gh pr view {pr['number']} --comments and the review threads) and "
                f"list every remark here with your view: agree / disagree and why / a question "
                f"for me. Change NOTHING and answer nobody until I decide. An approve: just say so.")
        key = re.sub(r"[^0-9A-Za-z.]+", "-", f"{pr['repo']}.{pr['number']}.{at}")
        deliver(r, text, STATE / "delivered" / f"pr.{key}", f"pr event {tag} ({did} by {who})")


def lane_merge_gate(prs: list, rows: list) -> None:
    for pr in prs:
        tag = f"{pr['repo']}#{pr['number']}"
        blockers = merge_blockers(pr)
        if blockers:
            log(f"merge gate {tag}: {'; '.join(blockers)}")
            continue
        r = session_for_branch(rows, pr.get("headRefName") or "")
        key = re.sub(r"[^0-9A-Za-z.]+", "-", f"{pr['repo']}.{pr['number']}.{pr.get('headRefOid', '')[:12]}")
        stamp = STATE / "delivered" / f"merge.{key}"
        if not r:
            if not stamp.exists():
                ctl("notify", f"{tag} passed the merge gate — no session on its branch; land it by hand",
                    "--title", "watch-lane")
                stamp.parent.mkdir(parents=True, exist_ok=True)
                stamp.write_text("notified\n", encoding="utf-8")
            continue
        text = (f"PR #{pr['number']} passed the merge gate: review, self-review and checks are all "
                f"green ({pr.get('url')}). Land it now — merge, watch the deploy, verify on the "
                f"environment — and do not ask me for confirmation: the gate is the approval.")
        deliver(r, text, stamp, f"merge gate {tag}")


def once() -> None:
    if not REPOS or not ME:
        sys.exit("watch-lane: set WATCH_REPOS=owner/name[,…] and WATCH_GH_LOGIN=<your login>")
    rows = sessions()
    if not rows:
        log("no agterm tree — is agterm running?")
        return
    prs = my_open_prs()
    lane_pr_events(prs, rows)
    lane_merge_gate(prs, rows)


def main() -> int:
    if "--once" in sys.argv:
        once()
        return 0
    log(f"start pid={os.getpid()} tick={TICK}s repos={','.join(REPOS)}")
    while True:
        try:
            once()
        except Exception as exc:  # noqa: BLE001 — a lane fault must never end the loop
            log(f"pass failed: {exc}")
        time.sleep(TICK)


if __name__ == "__main__":
    sys.exit(main())
