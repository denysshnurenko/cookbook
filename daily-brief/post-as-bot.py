#!/usr/bin/env python3
"""Post the brief's channel message as the Daily Brief bot.

Why a bot and not your own account: Slack raises no notification and no unread
badge for your OWN messages. #daily_meeting is a channel with a single member —
you — so a brief you post yourself arrives already-read and is easy to miss.
Sent by the bot it comes from a different identity, so it notifies normally.

Deliberately NOT fail-soft, unlike a ping: this call *is* the delivery of the
brief. A silent exit 0 would look like a posted brief while nothing landed, so
failures exit non-zero and the caller falls back to posting over MCP (under your
own name — no notification, but the brief still lands).

Input is STANDARD MARKDOWN and is converted to Slack mrkdwn before sending —
see to_mrkdwn(). chat.postMessage does NOT accept markdown: a `[text](url)` link
arrives as literal brackets. The MCP slack_send_message tool converts for you,
this endpoint does not, so the conversion has to live here. Keeping the caller's
input markdown means the same text also works via the MCP fallback and reads
correctly when printed for --dry-run.

Token: Keychain item 'slack-daily-brief-bot-token' (account = $USER), the same
convention the solidtime skill uses; $SLACK_BRIEF_BOT_TOKEN overrides it.
Target: --to, else channels[default_channel] from the skill's config.json.

Usage:
    post-as-bot.py "text"            # or:  ... | post-as-bot.py
    post-as-bot.py --to C0… "text"
    post-as-bot.py --update <ts> "text"   # rewrite a message already posted
    post-as-bot.py --show "text"          # print the converted text, send nothing
Prints the permalink of the posted message on success.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://slack.com/api/"
KEYCHAIN_SERVICE = "slack-daily-brief-bot-token"
# Your Slack workspace subdomain (<workspace>.slack.com), used to build permalinks.
# Read from config.json `slack.workspace`; $SLACK_WORKSPACE overrides.
WORKSPACE = os.environ.get("SLACK_WORKSPACE", "")
HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "..", "config.json")

# `code` spans are passed through untouched — Slack renders them the same way,
# and their contents must not be treated as markup.
CODE_SPAN = re.compile(r"`[^`\n]*`")
# [label](url), but not the ![alt](src) image form.
MD_LINK = re.compile(r"(?<!!)\[([^\]\n]*)\]\(\s*<?([^)\s]+)>?\s*\)")
MD_BOLD = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", re.S)
MD_STRIKE = re.compile(r"~~(?=\S)(.+?)(?<=\S)~~", re.S)


def die(msg):
    print(f"post-as-bot: {msg}", file=sys.stderr)
    sys.exit(1)


def _escape(text):
    """Slack requires exactly these three escaped in message text."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _convert_segment(seg):
    """Markdown → Slack mrkdwn for one non-code segment."""
    links = []

    def stash(m):
        label, url = m.group(1).strip(), m.group(2)
        links.append(f"<{url}|{_escape(label)}>" if label else f"<{url}>")
        return f"\x00{len(links) - 1}\x00"

    # Links first: their URLs must survive escaping unchanged.
    seg = MD_LINK.sub(stash, seg)
    seg = _escape(seg)
    seg = MD_BOLD.sub(r"*\1*", seg)      # Slack bold is a single asterisk
    seg = MD_STRIKE.sub(r"~\1~", seg)    # …and strike a single tilde
    return re.sub(r"\x00(\d+)\x00", lambda m: links[int(m.group(1))], seg)


def to_mrkdwn(text):
    """Convert standard markdown to Slack mrkdwn, leaving `code` spans alone."""
    out, pos = [], 0
    for m in CODE_SPAN.finditer(text):
        out.append(_convert_segment(text[pos:m.start()]))
        out.append(m.group(0))
        pos = m.end()
    out.append(_convert_segment(text[pos:]))
    return "".join(out)


def default_target():
    try:
        with open(CONFIG) as f:
            cfg = json.load(f)
        return cfg["channels"][cfg["default_channel"]]
    except (OSError, KeyError, ValueError) as exc:
        die(f"cannot resolve the default channel from config.json ({exc}); pass --to")


def load_token():
    tok = os.environ.get("SLACK_BRIEF_BOT_TOKEN")
    if tok:
        return tok.strip()
    try:
        out = subprocess.run(
            ["/usr/bin/security", "find-generic-password",
             "-a", os.environ.get("USER", ""), "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        die(f"keychain lookup failed: {exc}")
    if out.returncode != 0 or not out.stdout.strip():
        die(f"no bot token (keychain '{KEYCHAIN_SERVICE}' or $SLACK_BRIEF_BOT_TOKEN)")
    return out.stdout.strip()


def main():
    argv = sys.argv[1:]
    target = update_ts = None
    show_only = False
    while argv and argv[0].startswith("--"):
        flag = argv[0]
        if flag == "--show":
            show_only, argv = True, argv[1:]
            continue
        if flag not in ("--to", "--update"):
            break
        if len(argv) < 2:
            die(f"{flag} needs a value")
        if flag == "--to":
            target = argv[1]
        else:
            update_ts = argv[1]
        argv = argv[2:]

    text = " ".join(argv).strip()
    if not text and not sys.stdin.isatty():
        text = sys.stdin.read().strip()
    if not text:
        die("nothing to post (pass text as an argument or on stdin)")

    text = to_mrkdwn(text)
    if show_only:
        print(text)
        return 0

    target = target or default_target()
    token = load_token()

    method = "chat.update" if update_ts else "chat.postMessage"
    payload = {"channel": target, "text": text, "unfurl_links": False}
    if update_ts:
        payload["ts"] = update_ts
    req = urllib.request.Request(
        API + method,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json; charset=utf-8"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.load(resp)
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        die(f"Slack API call failed: {exc}")

    if not body.get("ok"):
        die(f"{method} failed: {body.get('error')}")

    ch, ts = body["channel"], body["ts"]
    print(f"https://{WORKSPACE}.slack.com/archives/{ch}/p{ts.replace('.', '')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
