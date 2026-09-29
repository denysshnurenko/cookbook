#!/usr/bin/env zsh
# harness worktree-setup: auto-configure the CURRENT worktree (cwd). Detection:
#   1. infra/worktree/setup.sh   → WORKTREE_NAME/WORKTREE_BASE_PORT
#   2. minimal fallback: symlink real .env* from the main checkout + install deps
# Runs inside the new worktree's session (cwd = the worktree).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

wt="$(git rev-parse --show-toplevel 2>/dev/null)" || { print "not a git repo"; exit 1; }
cd "$wt"
branch="${1:-$(git symbolic-ref --short -q HEAD)}"
main="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
base_port="${WORKTREE_BASE_PORT:-9000}"

# A fresh worktree is a fresh Claude Code "project", and a project starts with every claude.ai
# connector on. Disabling one is a PER-PROJECT flag (measured 2026-09-03 — there is no global
# one that spares Remote Control), so it has to be written before the first session, and this
# runs on the same command line as `claude`, just ahead of it. Best-effort and silent on
# failure: a worktree must still come up if the config cannot be written.
/usr/bin/python3 "$HOME/.config/harness/dispatcher/mcp-off.py" --path "$wt" 2>/dev/null

# apps to skip during `env sync` (e.g. ones whose Secret Manager you can't access
# but don't run locally). One app name per line in this file; '#' comments ok.
# Requires the CLI's --exclude/HCC_ENV_SYNC_EXCLUDE support (feat/cli-env-sync-exclude).
if [[ -f "$HOME/.config/harness/env-skip" ]]; then
  export HCC_ENV_SYNC_EXCLUDE="$(grep -vE '^[[:space:]]*#' "$HOME/.config/harness/env-skip" | tr '\n' ' ')"
  if [[ -n "${HCC_ENV_SYNC_EXCLUDE// }" ]]; then
    print "⏭️  env sync will skip: $HCC_ENV_SYNC_EXCLUDE"
    # the skip only works if this worktree's CLI actually reads the env var
    # (added in PR #948). A worktree branched off an older base silently ignores
    # it and env sync will still try — and fail on — those apps. Warn loudly.
    cli_sync="$wt/apps/cli/src/modules/env/sync.ts"
    if [[ -f "$cli_sync" ]] && ! grep -q 'HCC_ENV_SYNC_EXCLUDE' "$cli_sync"; then
      print "⚠️   …but THIS worktree's CLI predates the skip feature (PR #948),"
      print "     so env sync will still try those apps and may die on IAM."
      print "     → rebase onto master first:  git fetch origin master && git rebase origin/master"
    fi
    print ""
  fi
fi

print "🧪 configuring worktree"
print "   📂 path:   $wt"
print "   🌿 branch: $branch"
print "   🏠 main:   $main\n"

rc=0
if [[ -f "$wt/infra/worktree/setup.sh" ]]; then
  print "🛠️   infra/worktree/setup.sh\n"
  WORKTREE_NAME="$branch" WORKTREE_BASE_PORT="$base_port" zsh "$wt/infra/worktree/setup.sh" || rc=$?
else
  print "🔗 minimal fallback: symlink real .env* + install deps\n"
  ( cd "$main" && find . -maxdepth 4 -type f -name '.env*' ! -iname '*example*' -not -path '*/node_modules/*' -print ) \
  | while IFS= read -r rel; do
      rel="${rel#./}"
      src="$main/$rel"; dst="$wt/$rel"
      mkdir -p "${dst:h}"
      if [[ -e "$dst" || -L "$dst" ]]; then print "   ⏭️  skip $rel (exists)"; else ln -s "$src" "$dst"; print "   🔗 link $rel"; fi
    done
  print ""
  if   [[ -f pnpm-lock.yaml ]];     then print "📦 pnpm install\n";  pnpm install || rc=$?
  elif [[ -f yarn.lock ]];          then print "📦 yarn\n";          yarn || rc=$?
  elif [[ -f package-lock.json ]];  then print "📦 npm ci\n";        npm ci || rc=$?
  else print "   (no lockfile — skipping install)"; fi
fi

# ── VERIFY, then leave a marker (2026-09-30) ─────────────────────────────────────────────────
# Provisioning used to end on its own exit code and nothing else: nobody checked that what it
# set up actually answers, and no file said "this worktree is provisioned, with these ports" —
# so a session resumed after compaction re-ran the setup, and an agent that needed a port read
# `.env` (which the permission hook denies) instead of asking a file meant for it.
# Checks are the ones that cannot lie: the DB port from the repo's workspace state file
# accepts a connection; the lockfile's install exists. Both conditional on what the repo has,
# so the fallback path (no infra setup) still verifies what it did.
verify_ok=1
verify_notes=()
base_port_used=""; pg_port=""
ws_state="$wt/.hcc-workspace"
if [[ -f "$ws_state" ]]; then
  base_port_used="$(sed -n 's/^WORKTREE_BASE_PORT=//p' "$ws_state" | head -1)"
  # offset 5 of the port block is the workspace's PostgreSQL (infra/worktree/setup.sh)
  [[ -n "$base_port_used" ]] && pg_port=$((base_port_used + 5))
fi
if [[ -n "$pg_port" ]]; then
  if nc -z 127.0.0.1 "$pg_port" >/dev/null 2>&1; then
    verify_notes+=("pg 127.0.0.1:$pg_port answers")
  else
    verify_ok=0; verify_notes+=("pg: nothing listens on 127.0.0.1:$pg_port")
  fi
fi
if [[ -f pnpm-lock.yaml || -f yarn.lock || -f package-lock.json ]]; then
  if [[ -d "$wt/node_modules" ]]; then verify_notes+=("node_modules present")
  else verify_ok=0; verify_notes+=("node_modules missing"); fi
fi
if [[ -d "$wt/apps" ]]; then
  env_n="$(find "$wt/apps" -maxdepth 2 \( -name '.env' -o -name '.env.*' \) ! -name '*example*' 2>/dev/null | wc -l | tr -d ' ')"
  (( env_n > 0 )) && verify_notes+=("$env_n env file(s) under apps/") || verify_notes+=("no env files under apps/ yet (product env sync not run)")
fi

# The marker: `.harness/provisioned`, key=value, readable by any session in this worktree —
# ports live HERE so nobody has to open `.env` for them. `.harness/` is kept out of git through
# the repo's local `info/exclude` (shared by every worktree of the checkout, never committed),
# so the teardown preflight's `git status` does not count it as uncommitted work.
common="$(git rev-parse --git-common-dir 2>/dev/null)"
if [[ -n "$common" ]]; then
  mkdir -p "$common/info"
  grep -qx '.harness/' "$common/info/exclude" 2>/dev/null || print '.harness/' >> "$common/info/exclude"
fi
mkdir -p "$wt/.harness"
{
  print "provisioned=$(date -u +%FT%TZ)"
  print "branch=$branch"
  print "head=$(git rev-parse --short HEAD 2>/dev/null)"
  print "main=$main"
  print "base_port=${base_port_used:-}"
  print "pg_port=${pg_port:-}"
  print "setup_exit=$rc"
  print "verify=$(( verify_ok ))"
  for n in "${verify_notes[@]}"; do print "note=$n"; done
} > "$wt/.harness/provisioned"

print ""
for n in "${verify_notes[@]}"; do print "   ✔ $n" | sed "s/✔ \(.*nothing listens.*\|.*missing.*\)/✘ \1/"; done
if (( rc == 0 && verify_ok )); then
  print "\n🎉 worktree ready: $wt"
  [[ -n "$base_port_used" ]] && print "   ports: base $base_port_used · pg $pg_port  (also in .harness/provisioned)"
elif (( rc == 0 )); then
  print "\n⚠️  provisioning finished but VERIFY failed — see ✘ above; .harness/provisioned records it."
  rc=1
else
  print "\n💥 worktree + DB exist, but provisioning FAILED (exit $rc) — see the error above."
  print "   Fix the cause, then re-run in this dir:  worktree-setup.sh '$branch'"
fi
exit $rc
