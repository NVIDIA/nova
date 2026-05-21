#!/usr/bin/env bash
# Build (and optionally push) the Blossom Jenkins `nova-ci` container image.
#
# The image has two layers:
#   1. Public base from ci/Dockerfile (toolchain, ccache, clang, time, etc.).
#   2. Private layer that adds the internal `colossus` CLI to /usr/local/bin.
#
# `colossus` is NVIDIA-internal and not redistributable, so it is not in this
# repo. The script downloads the official Linux AMD64 release tarball from
# JFrog Artifactory (sw-ipp-colossus-generic) and installs it under
# /opt/colossus-cli with /usr/local/bin/colossus -> /opt/colossus-cli/colossus.
# Authentication uses ARTIFACTORY_USER + ARTIFACTORY_TOKEN, or whatever curl
# finds in ~/.netrc for artifactory.nvidia.com.
#
# Usage:
#   ci/build-image.sh                          # build only, tag = today (YYYY-MM-DD)
#   ci/build-image.sh --push                   # build + docker push
#   ci/build-image.sh --tag 2026-05-13         # explicit tag
#   ci/build-image.sh --push --tag 2026-05-13
#
# Environment overrides:
#   REGISTRY            gitlab-master.nvidia.com:5005
#   REPO                epeer/nova-test/nova-kernel-ci
#   COLOSSUS_VERSION    Colossus CLI version to install (default: latest in
#                       sw-ipp-colossus-generic/colossus-cli/).
#   COLOSSUS_TARBALL    Path to a local copy of colossus_cli_<v>_linux_amd64.tar.gz.
#                       When set, takes precedence over downloading.
#   ARTIFACTORY_USER    Artifactory account name (default: $USER).
#   ARTIFACTORY_TOKEN   Artifactory token / identity token. If unset, the script
#                       looks for ~/.config/artifactory-token, then falls back
#                       to whatever curl can find in ~/.netrc.
#   SKIP_COLOSSUS=1     Skip the private colossus layer entirely (Build / Test
#                       will work; Provision will not).
#   DOCKER              container CLI to invoke (default: docker).
#   PLATFORM            target platform (default: linux/amd64; Blossom k8s
#                       nodes are x86_64). On Apple Silicon hosts this triggers
#                       QEMU cross-build via buildx.

set -euo pipefail

REGISTRY="${REGISTRY:-gitlab-master.nvidia.com:5005}"
REPO="${REPO:-epeer/nova-test/nova-kernel-ci}"
DOCKER="${DOCKER:-docker}"
PLATFORM="${PLATFORM:-linux/amd64}"
ARTIFACTORY_HOST="${ARTIFACTORY_HOST:-artifactory.nvidia.com}"
ARTIFACTORY_REPO="${ARTIFACTORY_REPO:-sw-ipp-colossus-generic}"
ARTIFACTORY_USER="${ARTIFACTORY_USER:-${USER:-}}"

TAG="$(date +%Y-%m-%d)"
PUSH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)    TAG="$2"; shift 2 ;;
    --tag=*)  TAG="${1#--tag=}"; shift ;;
    --push)   PUSH=1; shift ;;
    -h|--help)
      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

IMAGE="${REGISTRY}/${REPO}:${TAG}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> target image:  ${IMAGE}"
echo "==> repo root:     ${REPO_ROOT}"

# Stage colossus next to the build context. The Dockerfile (and its private
# layer) only sees files inside the build context, so we drop the binary into
# a build-only directory we clean up at exit.
BUILD_CTX="$(mktemp -d -t nova-ci-build.XXXXXX)"
trap 'rm -rf "${BUILD_CTX}"' EXIT

echo "==> staging build context in ${BUILD_CTX}"
cp "${REPO_ROOT}/ci/Dockerfile" "${BUILD_CTX}/Dockerfile.base"

# Resolve the colossus tarball. Priority:
#   1. SKIP_COLOSSUS=1 -> skip private layer entirely (Provision stage will
#      not work, but Build / Test will).
#   2. $COLOSSUS_TARBALL if set (local file).
#   3. Download from JFrog Artifactory using $ARTIFACTORY_USER + $ARTIFACTORY_TOKEN,
#      ~/.config/artifactory-token, or whatever curl finds in ~/.netrc.
COLOSSUS_STAGED=""
COLOSSUS_VER=""
if [[ "${SKIP_COLOSSUS:-0}" -eq 1 ]]; then
  echo "==> SKIP_COLOSSUS=1; not installing colossus into the image"
elif [[ -n "${COLOSSUS_TARBALL:-}" ]]; then
  echo "==> using local COLOSSUS_TARBALL=${COLOSSUS_TARBALL}"
  cp "${COLOSSUS_TARBALL}" "${BUILD_CTX}/colossus-cli.tar.gz"
  COLOSSUS_VER="$(basename "${COLOSSUS_TARBALL}" | sed -nE 's/colossus_cli_([0-9.]+)_linux_amd64\.tar\.gz/\1/p')"
  COLOSSUS_STAGED=1
else
  # Resolve auth.
  CURL_AUTH=()
  if [[ -z "${ARTIFACTORY_TOKEN:-}" && -r "${HOME}/.config/artifactory-token" ]]; then
    ARTIFACTORY_TOKEN="$(tr -d '\n\r ' < "${HOME}/.config/artifactory-token")"
  fi
  if [[ -n "${ARTIFACTORY_TOKEN:-}" ]]; then
    : "${ARTIFACTORY_USER:?ARTIFACTORY_USER must be set (or invoke as your account)}"
    CURL_AUTH=(-u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}")
  else
    # Let curl pick up ~/.netrc (-n implies --netrc).
    CURL_AUTH=(-n)
  fi
  ARTI_BASE="https://${ARTIFACTORY_HOST}/artifactory/${ARTIFACTORY_REPO}/colossus-cli"
  ARTI_API="https://${ARTIFACTORY_HOST}/artifactory/api/storage/${ARTIFACTORY_REPO}/colossus-cli"
  if [[ -z "${COLOSSUS_VERSION:-}" ]]; then
    echo "==> resolving latest colossus version from ${ARTI_API}/"
    COLOSSUS_VERSION="$(curl -sf "${CURL_AUTH[@]}" "${ARTI_API}/" \
      | python3 -c "import json,sys; print(sorted([c['uri'].lstrip('/') for c in json.load(sys.stdin).get('children',[])], key=lambda s: [int(x) for x in s.split('.')])[-1])")"
  fi
  COLOSSUS_VER="${COLOSSUS_VERSION}"
  URL="${ARTI_BASE}/${COLOSSUS_VERSION}/colossus_cli_${COLOSSUS_VERSION}_linux_amd64.tar.gz"
  echo "==> downloading colossus ${COLOSSUS_VERSION} from ${URL}"
  curl -fsSL "${CURL_AUTH[@]}" -o "${BUILD_CTX}/colossus-cli.tar.gz" "${URL}"
  COLOSSUS_STAGED=1
fi

{
  echo "# syntax=docker/dockerfile:1"
  echo "# Generated by ci/build-image.sh. Do not edit; edit ci/Dockerfile or the script."
  echo
  echo "# --- public base (verbatim from ci/Dockerfile) ---"
  cat "${BUILD_CTX}/Dockerfile.base"
  if [[ -n "${COLOSSUS_STAGED}" ]]; then
    echo
    echo "# --- private layer: colossus CLI ${COLOSSUS_VER} (PyInstaller bundle) ---"
    echo "# Tarball contains a colossus-cli/ directory with colossus + _internal/."
    echo "COPY colossus-cli.tar.gz /tmp/colossus-cli.tar.gz"
    echo "RUN set -eux; \\"
    echo "    mkdir -p /opt; \\"
    echo "    tar -xzf /tmp/colossus-cli.tar.gz -C /opt; \\"
    echo "    chmod -R a+rX /opt/colossus-cli; \\"
    echo "    ln -s /opt/colossus-cli/colossus /usr/local/bin/colossus; \\"
    echo "    rm /tmp/colossus-cli.tar.gz"
  else
    echo
    echo "# colossus NOT included (SKIP_COLOSSUS=1)."
  fi
} > "${BUILD_CTX}/Dockerfile"

echo "==> docker build --platform ${PLATFORM} -t ${IMAGE}"
# Use buildx so cross-platform builds work transparently on Apple Silicon (QEMU
# binfmt is shipped with Docker Desktop). Load result into the local image
# store so the smoke check below can run it. Build context is the staging dir
# only -- the generated Dockerfile inlines ci/Dockerfile's content and copies
# only colossus-cli.tar.gz (already staged), so we don't need the repo root.
"${DOCKER}" buildx build \
  --pull \
  --platform "${PLATFORM}" \
  --load \
  -t "${IMAGE}" \
  "${BUILD_CTX}"

echo "==> smoke check (time, clang, ccache, rustc, bindgen, colossus on PATH)"
"${DOCKER}" run --rm --platform "${PLATFORM}" "${IMAGE}" sh -c '
  set -e
  /usr/bin/time --version 2>&1 | head -1
  clang --version | head -1
  ccache --version | head -1
  # rustc + bindgen are required for kbuild Rust support; without bindgen,
  # CONFIG_RUST flips to n at silentoldconfig time and CONFIG_NOVA_CORE /
  # CONFIG_DRM_NOVA disappear from the .config silently (build #65).
  rustc --version
  bindgen --version
  if command -v colossus >/dev/null 2>&1; then
    echo "colossus: $(ls -la "$(command -v colossus)")"
  else
    echo "colossus: NOT INSTALLED (Provision stage will not work in this image)"
  fi
'

if [[ "${PUSH}" -eq 1 ]]; then
  echo "==> docker push ${IMAGE}"
  "${DOCKER}" push "${IMAGE}"
  echo
  echo "Pushed ${IMAGE}"
  echo "Bump Jenkinsfile CI_IMAGE default (or pass it via Build with Parameters):"
  echo "  ${IMAGE}"
else
  echo
  echo "Built ${IMAGE} (not pushed; pass --push to push)."
fi
