#!/usr/bin/env python3
"""slack-token — post, edit and upload to Slack AS YOURSELF, over plain HTTP, with a user token.

No dependencies (stdlib only), no MCP, no model in the loop: one request per action, ~200 ms.

Token: a Slack USER token (`xoxp…`) from the Keychain item `slack-user-token` (account = $USER),
or $SLACK_USER_TOKEN for a one-off. `SLACK_TOKEN_KEYCHAIN` renames the item. See README.md for
how to get one.

    slack-token.py --check
    slack-token.py --post   --channel C123|D123|U123 [--thread TS] --file msg.md [--plate TEXT]
    slack-token.py --update --channel C123 --ts TS --file msg.md [--plate TEXT]
    slack-token.py --upload --channel C123 [--thread TS] --file report.pdf [--title T]

The text is standard Markdown (**bold**, [text](url), `code`) — sent as `markdown_text`, or as a
`markdown` block when a plate is added. `--plate` adds a small grey `context` block under the
text (Slack mrkdwn, e.g. "_Sent with <@U0CLAUDE>_"). Put a mention there, never in the text:
a bot mention in the message body makes Slack offer to add that bot to the conversation.

Exit codes: 0 ok · 1 Slack said no · 2 bad arguments / no token · 3 the token lacks a scope.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://slack.com/api/"
KEYCHAIN = os.environ.get("SLACK_TOKEN_KEYCHAIN", "slack-user-token")
TIMEOUT = 20


def token() -> str:
    tok = (os.environ.get("SLACK_USER_TOKEN") or "").strip()
    if tok:
        return tok
    try:
        out = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN,
                              "-a", os.environ.get("USER", ""), "-w"],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip()
    except Exception:  # noqa: BLE001 — not macOS, no Keychain: same as no token
        return ""


def call(method: str, tok: str, **params) -> dict:
    """One Web API call. Slack answers HTTP 200 with {"ok": false} for most errors, so `ok` is
    the check, not the status. A rate limit is worth exactly one wait (Retry-After)."""
    body = urllib.parse.urlencode({k: v for k, v in params.items() if v not in (None, "")})
    req = urllib.request.Request(API + method, data=body.encode(), headers={
        "Authorization": f"Bearer {tok}",
        "Content-Type": "application/x-www-form-urlencoded; charset=utf-8"})
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                data = json.loads(resp.read().decode("utf-8", "replace"))
                data["_scopes"] = resp.headers.get("x-oauth-scopes", "")
        except urllib.error.HTTPError as exc:
            if exc.code == 429 and attempt == 1:
                time.sleep(int(exc.headers.get("Retry-After") or 5))
                continue
            return {"ok": False, "error": f"http {exc.code}"}
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": str(exc)}
        if data.get("error") == "ratelimited" and attempt == 1:
            time.sleep(5)
            continue
        return data
    return {"ok": False, "error": "ratelimited"}


def body(text: str, plate: str) -> dict:
    # `markdown_text` cannot be combined with `blocks`, so a plated message is a `markdown`
    # block + a `context` block, with `text` as the notification fallback.
    if not plate:
        return {"markdown_text": text}
    blocks = [{"type": "markdown", "text": text},
              {"type": "context", "elements": [{"type": "mrkdwn", "text": plate}]}]
    return {"text": text, "blocks": json.dumps(blocks, ensure_ascii=False)}


def upload(tok: str, channel: str, thread: str, path: str, title: str) -> dict:
    """Slack's external upload is three calls: ask for a signed URL (EXACT byte length), POST the
    raw bytes there, then complete it with a destination — until then the file is nowhere."""
    data = Path(path).read_bytes()
    got = call("files.getUploadURLExternal", tok, filename=os.path.basename(path),
               length=len(data))
    if not got.get("ok"):
        return got
    req = urllib.request.Request(got["upload_url"], data=data, method="POST",
                                 headers={"Content-Type": "application/octet-stream"})
    try:
        urllib.request.urlopen(req, timeout=TIMEOUT).read()
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"upload POST failed: {exc}"}
    files = json.dumps([{"id": got["file_id"], "title": title or os.path.basename(path)}])
    return call("files.completeUploadExternal", tok, files=files, channel_id=channel,
                thread_ts=thread)


def permalink(tok: str, channel: str, ts: str) -> str:
    return call("chat.getPermalink", tok, channel=channel, message_ts=ts).get("permalink") or ""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    for m in ("check", "post", "update", "upload"):
        mode.add_argument(f"--{m}", action="store_true")
    ap.add_argument("--channel")
    ap.add_argument("--thread", default="")
    ap.add_argument("--ts")
    ap.add_argument("--file")
    ap.add_argument("--plate", default="")
    ap.add_argument("--title", default="")
    a = ap.parse_args()

    tok = token()
    if not tok:
        print(f"no token: Keychain item '{KEYCHAIN}' is empty and $SLACK_USER_TOKEN is unset",
              file=sys.stderr)
        return 2
    if a.check:
        who = call("auth.test", tok)
        if not who.get("ok"):
            print(f"auth.test failed: {who.get('error')}", file=sys.stderr)
            return 1
        kind = "user token" if tok.startswith("xoxp") else "NOT a user token (want xoxp)"
        print(f"{who.get('user')} ({who.get('user_id')}) in {who.get('team')} — {kind}")
        print(f"scopes: {who.get('_scopes') or '?'}")
        return 0

    need = {"post": ("channel", "file"), "update": ("channel", "ts", "file"),
            "upload": ("channel", "file")}
    m = next(k for k in need if getattr(a, k))
    missing = [f"--{n}" for n in need[m] if not getattr(a, n)]
    if missing:
        print(f"--{m} needs {' '.join(missing)}", file=sys.stderr)
        return 2

    if m == "upload":
        got = upload(tok, a.channel, a.thread, a.file, a.title)
    else:
        text = Path(a.file).read_text(encoding="utf-8").strip()
        if m == "post":
            got = call("chat.postMessage", tok, channel=a.channel, thread_ts=a.thread,
                       **body(text, a.plate))
        else:
            got = call("chat.update", tok, channel=a.channel, ts=a.ts, **body(text, a.plate))
    if not got.get("ok"):
        err = str(got.get("error"))
        print(f"{m} failed: {err}" + (f" — add the scope it needs ({got.get('needed', '?')})"
                                      if err == "missing_scope" else ""), file=sys.stderr)
        return 3 if err == "missing_scope" else 1
    if m == "upload":
        print((got.get("files") or [{}])[0].get("permalink") or "uploaded")
    else:
        print(permalink(tok, got.get("channel") or a.channel, got.get("ts") or a.ts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
