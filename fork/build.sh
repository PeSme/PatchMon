#!/usr/bin/env bash
# =============================================================================
# Build the PeSme fork of the PatchMon server image.
#
# Mirrors docker/build.sh (upstream's local build) but stamps a fork version so
# agents on your hosts actually pick up the fork's agent changes:
#
#   <next patch after the last upstream release>-pesme.<commits since it>
#   e.g. upstream v2.1.6 + 17 commits  ->  2.1.7-pesme.17
#
# That sorts above the official 2.1.6 (hosts auto-update to the fork agent) and
# below the official 2.1.7 (the UI shows "update available" once upstream
# releases, which is your cue to run fork/sync.sh).
#
# Used both by CI (.github/workflows/fork-image.yml) and for local builds.
#
# Usage:
#   fork/build.sh                      # build image patchmon-server:fork
#   fork/build.sh --tag mytag          # image tag
#   fork/build.sh --print-version      # just print the computed version
#
# Env:
#   CONTAINER_CLI   docker (default) or podman
#   IMAGE           image name (default: patchmon-server)
#   BASE_IMAGE      runtime base image. Default: dhi.io/alpine-base:3.23 (needs
#                   `docker login dhi.io`). Without access, set it to
#                   ghcr.io/patchmon/patchmon-server:latest, the official image,
#                   which is itself built on that hardened base.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLI="${CONTAINER_CLI:-docker}"
IMAGE="${IMAGE:-patchmon-server}"
TAG="fork"
PRINT_VERSION=false
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --print-version) PRINT_VERSION=true; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# Upstream release tags live on the upstream remote; make sure we have them.
if ! git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*' >/dev/null 2>&1; then
  git fetch --tags --quiet https://github.com/PatchMon/PatchMon.git || true
fi
BASE_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*')"
BASE="${BASE_TAG#v}"
IFS=. read -r MAJ MIN PAT <<<"$BASE"
COUNT="$(git rev-list --count "${BASE_TAG}..HEAD")"
VERSION="${MAJ}.${MIN}.$((PAT + 1))-pesme.${COUNT}"

if $PRINT_VERSION; then echo "$VERSION"; exit 0; fi
echo "==> Version: $VERSION (upstream base $BASE_TAG, $(git rev-parse --short HEAD))"

echo "==> Building agent binaries"
rm -rf agents-prebuilt && mkdir -p agents-prebuilt
( cd agent-source-code
  for target in linux/amd64 linux/arm64 linux/386 linux/arm \
                freebsd/amd64 freebsd/arm64 freebsd/386 freebsd/arm \
                windows/amd64 windows/arm64; do
    GOOS=${target%/*}; GOARCH=${target#*/}; export GOOS GOARCH CGO_ENABLED=0
    case "$GOARCH" in arm) export GOARM=6 ;; *) unset GOARM ;; esac
    SUFFIX=""; [ "$GOOS" = windows ] && SUFFIX=".exe"
    go build -buildvcs=false \
      -ldflags="-s -w -X patchmon-agent/internal/pkgversion.Version=$VERSION" \
      -o "../agents-prebuilt/patchmon-agent-${GOOS}-${GOARCH}${SUFFIX}" ./cmd/patchmon-agent
  done )

echo "==> Building frontend for embed"
npm ci --workspace=frontend --include=dev --include-workspace-root
npm run build --workspace=frontend
rm -rf server-source-code/cmd/server/static/frontend/dist
mkdir -p server-source-code/cmd/server/static/frontend
cp -r frontend/dist server-source-code/cmd/server/static/frontend/

echo "==> Building server binaries"
mkdir -p server-prebuilt
for arch in amd64 arm64; do
  ( cd server-source-code && \
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -buildvcs=false \
      -ldflags="-s -w -X github.com/PatchMon/PatchMon/server-source-code/internal/config.DefaultVersion=${VERSION}" \
      -o "../server-prebuilt/patchmon-server-linux-${arch}" ./cmd/server )
done

DOCKERFILE=docker/server.Dockerfile
if [ -n "${BASE_IMAGE:-}" ]; then
  DOCKERFILE="$(mktemp "${TMPDIR:-/tmp}/server.Dockerfile.XXXXXX")"
  trap 'rm -f "$DOCKERFILE"' EXIT
  sed "s#^FROM dhi.io/alpine-base:[^ ]*#FROM ${BASE_IMAGE}#" docker/server.Dockerfile >"$DOCKERFILE"
  grep -q "^FROM ${BASE_IMAGE}" "$DOCKERFILE" || { echo "error: runtime FROM line not found in docker/server.Dockerfile" >&2; exit 1; }
  echo "==> Runtime base overridden: $BASE_IMAGE"
fi

echo "==> Building image ${IMAGE}:${TAG}"
EXTRA_ARGS=()
[ -n "${SSG_VERSION:-}" ] && EXTRA_ARGS+=(--build-arg "SSG_VERSION=${SSG_VERSION}")
# podman defaults to OCI format, which drops HEALTHCHECK.
[ "$(basename "$CLI")" = podman ] && EXTRA_ARGS+=(--format docker)
"$CLI" build -f "$DOCKERFILE" "${EXTRA_ARGS[@]}" \
  --label "org.opencontainers.image.version=${VERSION}" \
  --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
  --label "org.opencontainers.image.source=https://github.com/PeSme/PatchMon" \
  -t "${IMAGE}:${TAG}" .

echo "Built ${IMAGE}:${TAG} reporting version ${VERSION}"
