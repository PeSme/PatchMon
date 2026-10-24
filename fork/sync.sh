#!/usr/bin/env bash
# =============================================================================
# Rebase the fork's patch stack onto the latest upstream and push it.
#
# The fork's `main` is always: upstream/main + a short stack of fork commits
# (PR #855, PR #856, fork tooling). This script replays that stack on top of the
# newest upstream, checks that everything still compiles, and force-pushes
# (with lease) to origin/main. The push triggers .github/workflows/fork-image.yml,
# which builds and publishes ghcr.io/pesme/patchmon-server:latest.
#
# Usage:
#   fork/sync.sh                 # rebase onto upstream/main, verify, push
#   fork/sync.sh --onto v2.1.7   # rebase onto a release tag instead of main
#   fork/sync.sh --no-push       # rebase + verify only
#   fork/sync.sh --continue      # after resolving a conflict by hand
#
# Conflicts: git rerere is enabled, so a conflict you resolved once is replayed
# automatically next time. For conflicts in sqlc-generated code
# (server-source-code/internal/db/*.go) do not hand-merge: run
#   fork/sync.sh --regen-sqlc
# which takes upstream's version and regenerates from the merged .sql files.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UPSTREAM_URL="https://github.com/PatchMon/PatchMon.git"
ONTO="upstream/main"
PUSH=true
MODE=sync
while [ $# -gt 0 ]; do
  case "$1" in
    --onto) ONTO="$2"; shift 2 ;;
    --no-push) PUSH=false; shift ;;
    --continue) MODE=continue; shift ;;
    --regen-sqlc) MODE=regen; shift ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
rebasing() { [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; }

sqlc_bin() {
  command -v sqlc 2>/dev/null && return
  local bin; bin="$(go env GOPATH)/bin/sqlc"
  [ -x "$bin" ] || GOBIN="$(go env GOPATH)/bin" go install github.com/sqlc-dev/sqlc/cmd/sqlc@v1.30.0
  echo "$bin"
}

verify() {
  say "Verifying the result compiles"
  # go:embed needs a dist/ dir; an empty placeholder is enough for vet/build.
  local dist=server-source-code/cmd/server/static/frontend/dist created=false
  if [ ! -d "$dist" ]; then mkdir -p "$dist" && touch "$dist/.placeholder" && created=true; fi
  ( cd server-source-code && go vet ./... )
  ( cd agent-source-code && go vet ./... && GOOS=windows go build ./... && GOOS=freebsd go build ./... )
  $created && rm -rf "$dist"
  # sqlc output must match the queries/schema, otherwise a rebase silently lost something.
  ( cd server-source-code && "$(sqlc_bin)" diff ) || die "sqlc output is stale: run fork/sync.sh --regen-sqlc and amend the commit"
  if command -v npx >/dev/null; then npx --no-install biome check frontend/src >/dev/null || die "biome check failed (npx biome check frontend/src)"; fi
}

finish() {
  verify
  say "Fork commits on top of $(git describe --tags --always "$ONTO"):"
  git log --oneline "$ONTO"..HEAD
  if $PUSH; then
    git push --force-with-lease origin HEAD:main
    disable_upstream_workflows
    say "Pushed. CI builds ghcr.io/pesme/patchmon-server: gh run watch -R PeSme/PatchMon"
  fi
}

# Upstream's workflows (Discord notifications, Harbor pushes, deploys, ...) come
# along with every sync. Keep only the fork-* ones enabled.
disable_upstream_workflows() {
  command -v gh >/dev/null || return 0
  gh workflow list -R PeSme/PatchMon --all --json path,state \
    --jq '.[] | select(.state=="active") | .path | select(test("/fork-") | not)' |
    while read -r wf; do
      say "Disabling upstream workflow $wf"
      gh workflow disable -R PeSme/PatchMon "$(basename "$wf")" || true
    done
}

git config rerere.enabled true
git config rerere.autoupdate true
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"

case "$MODE" in
  regen)
    rebasing || die "not in the middle of a rebase"
    say "Taking upstream's generated sqlc code and regenerating"
    # During a rebase "ours" is the new upstream base.
    git diff --name-only --diff-filter=U -- server-source-code/internal/db | xargs -r git checkout --ours --
    ( cd server-source-code && "$(sqlc_bin)" generate )
    git add server-source-code/internal/db
    say "Done. Resolve any remaining conflicts, then: fork/sync.sh --continue"
    exit 0 ;;
  continue)
    rebasing || die "not in the middle of a rebase"
    git add -A
    GIT_EDITOR=true git -c core.hooksPath=/dev/null rebase --continue || die "more conflicts: resolve them, then run fork/sync.sh --continue again"
    finish
    exit 0 ;;
esac

rebasing && die "a rebase is in progress: resolve it and run fork/sync.sh --continue (or git rebase --abort)"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "check out main first"
git diff --quiet && git diff --cached --quiet || die "working tree has uncommitted changes"

say "Fetching upstream and origin"
git fetch --quiet --tags upstream
git fetch --quiet origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "local main differs from origin/main; reconcile first (git status / git log origin/main...main)"

if git merge-base --is-ancestor "$ONTO" HEAD; then
  say "Already up to date with $ONTO"
  exit 0
fi

OLD_BASE="$(git merge-base HEAD upstream/main)"
say "$(git rev-list --count "$OLD_BASE..$ONTO") new upstream commit(s) since last sync"
BACKUP="backup/main-$(date +%Y%m%d-%H%M%S)"
git branch "$BACKUP" HEAD
say "Saved current main as $BACKUP"

# Hooks are skipped: upstream's lefthook runs the whole test suite per commit.
if ! GIT_EDITOR=true git -c core.hooksPath=/dev/null rebase --onto "$ONTO" "$OLD_BASE" main; then
  cat <<EOF

Rebase stopped on a conflict that rerere could not resolve.
  - see conflicts:        git status
  - sqlc-generated files: fork/sync.sh --regen-sqlc
  - after fixing:         fork/sync.sh --continue
  - give up:              git rebase --abort   (main is untouched; backup in $BACKUP)
EOF
  exit 1
fi
finish
