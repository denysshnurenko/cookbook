#!/usr/bin/env bash
# Collect GitHub activity for a Kyiv-time window (single day or range).
#
# Usage:
#   collect-github.sh <gh_user> <YYYY-MM-DD from> <YYYY-MM-DD to> [HH:MM time_from] [HH:MM time_to]
#
# Examples:
#   collect-github.sh denys 2026-05-13 2026-05-13                    # full day
#   collect-github.sh denys 2026-05-13 2026-05-13 10:00 23:59        # 10:00 onwards
#   collect-github.sh denys 2026-05-09 2026-05-11 10:00 23:59        # Fri→Sun, Fri from 10:00
#
# time_from defaults to 00:00, time_to to 23:59. Both apply at Kyiv local time
# (UTC+3). Internally the script converts to UTC for API filtering.
#
# Output: single JSON object to stdout.

set -euo pipefail

GH_USER="${1:?usage: collect-github.sh <gh_user> <date_from> <date_to> [time_from] [time_to]}"
DATE_FROM="${2:?missing date_from YYYY-MM-DD}"
DATE_TO="${3:?missing date_to YYYY-MM-DD}"
TIME_FROM="${4:-00:00}"
TIME_TO="${5:-23:59}"

to_utc_iso() {
  python3 -c "
import sys
from datetime import datetime, timezone, timedelta
dt = datetime.strptime(sys.argv[1], '%Y-%m-%d %H:%M').replace(tzinfo=timezone(timedelta(hours=3)))
print(dt.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$1"
}

FROM_UTC=$(to_utc_iso "$DATE_FROM $TIME_FROM")
TO_UTC=$(to_utc_iso "$DATE_TO $TIME_TO")

# For GitHub search/list endpoints that take date-only filters, we widen to the
# full UTC date span and then filter by ISO timestamp.
SEARCH_FROM_DATE="${FROM_UTC%%T*}"
SEARCH_TO_DATE="${TO_UTC%%T*}"
DATE_RANGE="${SEARCH_FROM_DATE}..${SEARCH_TO_DATE}"

# --- 1. Commits (GitHub-wide search by author) ---------------------------
COMMITS=$(gh api -H "Accept: application/vnd.github.cloak-preview+json" \
  "/search/commits?q=author:${GH_USER}+author-date:${DATE_RANGE}&per_page=100&sort=author-date&order=asc" \
  --jq "[.items[] | select(.commit.author.date >= \"${FROM_UTC}\" and .commit.author.date <= \"${TO_UTC}\") | {
    date: .commit.author.date,
    repo: .repository.full_name,
    sha: .sha,
    short_sha: .sha[0:9],
    url: .html_url,
    message: (.commit.message | split(\"\\n\")[0])
  }]" 2>/dev/null || echo "[]")

# --- 2. Discover relevant repos ------------------------------------------
# Repos to check for Actions runs even when you pushed no commit to them in the window
# (a deploy you triggered, a scheduled job you care about). Space-separated "owner/name".
BASELINE_REPOS="${DAILY_BRIEF_BASELINE_REPOS:-}"
COMMIT_REPOS=$(echo "$COMMITS" | jq -r '.[].repo' 2>/dev/null | sort -u)
REPOS=$(echo -e "${COMMIT_REPOS}\n${BASELINE_REPOS}" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

# --- 3. Actions runs -----------------------------------------------------
ACTIONS_ARRAY="[]"
while IFS= read -r REPO; do
  [ -z "$REPO" ] && continue
  runs=$(gh api "/repos/${REPO}/actions/runs?actor=${GH_USER}&created=${DATE_RANGE}&per_page=100" \
    --jq "[.workflow_runs[] | select(.created_at >= \"${FROM_UTC}\" and .created_at <= \"${TO_UTC}\") | {
      date: .created_at,
      repo: \"${REPO}\",
      sha: .head_sha,
      short_sha: .head_sha[0:9],
      branch: .head_branch,
      event: .event,
      workflow: .name,
      conclusion: .conclusion,
      message: (.head_commit.message // \"\" | split(\"\\n\")[0]),
      url: .html_url
    }]" 2>/dev/null || echo "[]")
  ACTIONS_ARRAY=$(jq -s 'add' <<<"$ACTIONS_ARRAY $runs")
done <<<"$REPOS"

ACTIONS_REPOS=$(echo "$ACTIONS_ARRAY" | jq -r '.[].repo' 2>/dev/null | sort -u)
REPOS=$(echo -e "${COMMIT_REPOS}\n${BASELINE_REPOS}\n${ACTIONS_REPOS}" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

# --- 4. PRs (created / merged / reviewed) --------------------------------
PRS_CREATED=$(gh search prs --author "$GH_USER" --created "$DATE_RANGE" \
  --json number,title,url,state,createdAt,repository --limit 50 2>/dev/null | \
  jq "[.[] | select(.createdAt >= \"${FROM_UTC}\" and .createdAt <= \"${TO_UTC}\") | {
    number, title, url, state, createdAt, repo: .repository.nameWithOwner
  }]" || echo "[]")

PRS_MERGED=$(gh search prs --author "$GH_USER" --merged "$DATE_RANGE" \
  --json number,title,url,closedAt,repository --limit 50 2>/dev/null | \
  jq "[.[] | select(.closedAt >= \"${FROM_UTC}\" and .closedAt <= \"${TO_UTC}\") | {
    number, title, url, closedAt, repo: .repository.nameWithOwner
  }]" || echo "[]")

PRS_REVIEWED=$(gh search prs --reviewed-by "$GH_USER" --updated "$DATE_RANGE" \
  --json number,title,url,updatedAt,repository --limit 50 2>/dev/null | \
  jq "[.[] | {number, title, url, updatedAt, repo: .repository.nameWithOwner}]" || echo "[]")

# --- 5. Commit comments --------------------------------------------------
COMMIT_COMMENTS_ARRAY="[]"
while IFS= read -r REPO; do
  [ -z "$REPO" ] && continue
  comments=$(gh api "/repos/${REPO}/comments?per_page=100&sort=created&direction=desc" \
    --jq "[.[] | select(.user.login == \"${GH_USER}\") | select(.created_at >= \"${FROM_UTC}\" and .created_at <= \"${TO_UTC}\") | {
      date: .created_at,
      repo: \"${REPO}\",
      sha: .commit_id,
      short_sha: .commit_id[0:9],
      url: .html_url,
      body: (.body // \"\" | split(\"\\n\")[0])
    }]" 2>/dev/null || echo "[]")
  COMMIT_COMMENTS_ARRAY=$(jq -s 'add' <<<"$COMMIT_COMMENTS_ARRAY $comments")
done <<<"$REPOS"

# --- 6. PR review comments (line-level) ----------------------------------
PR_REVIEW_COMMENTS_ARRAY="[]"
while IFS= read -r REPO; do
  [ -z "$REPO" ] && continue
  comments=$(gh api "/repos/${REPO}/pulls/comments?per_page=100&sort=created&direction=desc" \
    --jq "[.[] | select(.user.login == \"${GH_USER}\") | select(.created_at >= \"${FROM_UTC}\" and .created_at <= \"${TO_UTC}\") | {
      date: .created_at,
      repo: \"${REPO}\",
      pr_url: .pull_request_url,
      url: .html_url,
      body: (.body // \"\" | split(\"\\n\")[0])
    }]" 2>/dev/null || echo "[]")
  PR_REVIEW_COMMENTS_ARRAY=$(jq -s 'add' <<<"$PR_REVIEW_COMMENTS_ARRAY $comments")
done <<<"$REPOS"

# --- 7. Issue / PR conversation comments ---------------------------------
ISSUE_COMMENTS_ARRAY="[]"
while IFS= read -r REPO; do
  [ -z "$REPO" ] && continue
  comments=$(gh api "/repos/${REPO}/issues/comments?per_page=100&sort=created&direction=desc" \
    --jq "[.[] | select(.user.login == \"${GH_USER}\") | select(.created_at >= \"${FROM_UTC}\" and .created_at <= \"${TO_UTC}\") | {
      date: .created_at,
      repo: \"${REPO}\",
      issue_url: .issue_url,
      url: .html_url,
      body: (.body // \"\" | split(\"\\n\")[0])
    }]" 2>/dev/null || echo "[]")
  ISSUE_COMMENTS_ARRAY=$(jq -s 'add' <<<"$ISSUE_COMMENTS_ARRAY $comments")
done <<<"$REPOS"

# --- Combine and emit ----------------------------------------------------
jq -n \
  --argjson commits "$COMMITS" \
  --argjson actions_runs "$ACTIONS_ARRAY" \
  --argjson prs_created "$PRS_CREATED" \
  --argjson prs_merged "$PRS_MERGED" \
  --argjson prs_reviewed "$PRS_REVIEWED" \
  --argjson commit_comments "$COMMIT_COMMENTS_ARRAY" \
  --argjson pr_review_comments "$PR_REVIEW_COMMENTS_ARRAY" \
  --argjson issue_comments "$ISSUE_COMMENTS_ARRAY" \
  --arg from_utc "$FROM_UTC" \
  --arg to_utc "$TO_UTC" \
  --arg gh_user "$GH_USER" \
  '{
    user: $gh_user,
    window: {from: $from_utc, to: $to_utc},
    commits: $commits,
    actions_runs: $actions_runs,
    prs_created: $prs_created,
    prs_merged: $prs_merged,
    prs_reviewed: $prs_reviewed,
    commit_comments: $commit_comments,
    pr_review_comments: $pr_review_comments,
    issue_comments: $issue_comments
  }'
