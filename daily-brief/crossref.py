#!/usr/bin/env python3
"""Cross-reference all collected sources by task ID.

Two id spaces are matched at once, which is what you want while migrating between
trackers — old commits keep pointing at the old system for months:
  * Tracker issue numbers — from `<TRACKER_HOST>/issues/<number>` links (a bare `#42`
    is intentionally NOT matched, since GitHub PR/issue refs use `#<n>` too) and
    `dtiss:...` machine ids (DOTT's internal issue id).
  * Legacy 10-digit ids   — still present in older commit messages and branch names.

Set TRACKER_HOST to your tracker's web host (e.g. "tracker.example.com").

Reads combined JSON from stdin (or first CLI arg as file path).
Writes grouped JSON to stdout.
"""

import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path


TASK_RE = re.compile(r"\b(\d{10})\b")                       # legacy monday item id
US_RE = re.compile(r"\bus(\d{9,})\b", re.IGNORECASE)        # legacy monday `usNNNN` branch
TRACKER_HOST = os.environ.get("TRACKER_HOST", "")            # e.g. "tracker.example.com"
DOTT_URL_RE = re.compile(                                    # tracker issue number
    re.escape(TRACKER_HOST) + r"/issues/(\d+)" if TRACKER_HOST else r"(?!x)x",
    re.IGNORECASE)
DOTT_MID_RE = re.compile(r"\b(dtiss[:_][A-Za-z0-9:_-]+)")   # DOTT issue machine id


def extract_ids(text):
    if not isinstance(text, str):
        return []
    ids = set(TASK_RE.findall(text))
    ids.update(US_RE.findall(text))
    ids.update(DOTT_URL_RE.findall(text))
    ids.update(DOTT_MID_RE.findall(text))
    return sorted(ids)


def empty_bucket():
    return {
        "commits": [], "actions_runs": [],
        "prs_created": [], "prs_merged": [], "prs_reviewed": [],
        "commit_comments": [], "pr_review_comments": [], "issue_comments": [],
        "slack_messages": [],
        "dott_issues": [], "dott_comments": [],
        "claude_sessions": [],
    }


def main():
    if len(sys.argv) > 1 and sys.argv[1] not in ("-", "/dev/stdin"):
        src = Path(sys.argv[1]).read_text()
    else:
        src = sys.stdin.read()
    data = json.loads(src)

    by_id = defaultdict(empty_bucket)
    unmatched = defaultdict(list)

    def assign(category, item, *fields):
        text = " ".join(str(item.get(f, "") or "") for f in fields)
        ids = extract_ids(text)
        if ids:
            for tid in ids:
                by_id[tid][category].append(item)
        else:
            unmatched[category].append(item)

    gh = data.get("github", {})
    for c in gh.get("commits", []):
        assign("commits", c, "message")
    for a in gh.get("actions_runs", []):
        assign("actions_runs", a, "message", "branch")
    for p in gh.get("prs_created", []):
        assign("prs_created", p, "title")
    for p in gh.get("prs_merged", []):
        assign("prs_merged", p, "title")
    for p in gh.get("prs_reviewed", []):
        assign("prs_reviewed", p, "title")
    for c in gh.get("commit_comments", []):
        assign("commit_comments", c, "body")
    for c in gh.get("pr_review_comments", []):
        assign("pr_review_comments", c, "body", "pr_url")
    for c in gh.get("issue_comments", []):
        assign("issue_comments", c, "body", "issue_url")

    slack = data.get("slack", {})
    for m in slack.get("messages", []):
        text = (m.get("text") or "") + " " + (m.get("permalink") or "")
        ids = extract_ids(text)
        if ids:
            for tid in ids:
                by_id[tid]["slack_messages"].append(m)
        else:
            unmatched["slack_messages"].append(m)

    # DOTT: pass {"dott": {"issues": [...], "comments": [...]}}.
    # Each issue carries `number` (the human `#N`) and `id` (`dtiss:...`); each
    # comment carries `issue_number` and/or `issue_id` pointing at its parent.
    # Register issues under BOTH keys so `/issues/N` links and `dtiss:` refs group.
    dott = data.get("dott", {})
    for issue in dott.get("issues", []):
        keys = [str(k) for k in (issue.get("number"), issue.get("id")) if k]
        if keys:
            for k in keys:
                by_id[k]["dott_issues"].append(issue)
        else:
            unmatched["dott_issues"].append(issue)
    for c in dott.get("comments", []):
        key = str(c.get("issue_number") or c.get("issue_id") or "")
        if key:
            by_id[key]["dott_comments"].append(c)
        else:
            unmatched["dott_comments"].append(c)

    claude = data.get("claude", {})
    for s in claude.get("sessions", []):
        text = " ".join(m.get("text", "") for m in s.get("user_messages_sample", []))
        text += " " + " ".join(s.get("bash_commands_sample", []))
        text += " " + " ".join(s.get("edited_files", []))
        text += " " + s.get("project_path", "") + " " + s.get("encoded_dir", "")
        ids = extract_ids(text)
        if ids:
            for tid in ids:
                by_id[tid]["claude_sessions"].append(s)
        else:
            unmatched["claude_sessions"].append(s)

    unmatched_clean = {k: v for k, v in unmatched.items() if v}

    print(json.dumps({
        "by_task_id": dict(by_id),
        "unmatched": unmatched_clean,
    }, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
