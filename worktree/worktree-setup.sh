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

if (( rc == 0 )); then
  print "\n🎉 worktree ready: $wt"
else
  print "\n💥 worktree + DB exist, but provisioning FAILED (exit $rc) — see the error above."
  print "   Fix the cause, then re-run in this dir:  worktree-setup.sh '$branch'"
fi
exit $rc
