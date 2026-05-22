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
# Usage (local dev, builds + smoke-tests with the host's docker):
#   ci/build-image.sh                          # build only, tag = today (YYYY-MM-DD)
#   ci/build-image.sh --push                   # build + docker push
#   ci/build-image.sh --tag 2026-05-13         # explicit tag
#   ci/build-image.sh --push --tag 2026-05-13
#
# Usage (Jenkins / kaniko -- stage the build context but do not invoke docker):
#   ci/build-image.sh --stage-only DIR --tag 2026-05-22-deadbeef
#       writes Dockerfile + buildroot.config + overlay/ + colossus-cli.tar.gz
#       into DIR, ready for `kaniko --context=dir://DIR --dockerfile=DIR/Dockerfile`.
#       Skips the `docker buildx build`, the smoke check, and the push.
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
#   DOCKER              container CLI to invoke (default: docker). Unused with
#                       --stage-only.
#   PLATFORM            target platform (default: linux/amd64; Blossom k8s
#                       nodes are x86_64). On Apple Silicon hosts this triggers
#                       QEMU cross-build via buildx (slow + flaky; see #67 --
#                       prefer ci/Jenkinsfile.image + kaniko on a real x86 node).

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
STAGE_ONLY_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)          TAG="$2"; shift 2 ;;
    --tag=*)        TAG="${1#--tag=}"; shift ;;
    --push)         PUSH=1; shift ;;
    --stage-only)   STAGE_ONLY_DIR="$2"; shift 2 ;;
    --stage-only=*) STAGE_ONLY_DIR="${1#--stage-only=}"; shift ;;
    -h|--help)
      sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "${STAGE_ONLY_DIR}" && "${PUSH}" -eq 1 ]]; then
  echo "--stage-only and --push are mutually exclusive (kaniko does the push)" >&2
  exit 2
fi

IMAGE="${REGISTRY}/${REPO}:${TAG}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> target image:  ${IMAGE}"
echo "==> repo root:     ${REPO_ROOT}"

# Stage colossus next to the build context. The Dockerfile (and its private
# layer) only sees files inside the build context, so we drop the binary into
# a build-only directory we clean up at exit -- unless --stage-only was passed,
# in which case the caller (kaniko in the Jenkins pipeline) owns the dir.
if [[ -n "${STAGE_ONLY_DIR}" ]]; then
  mkdir -p "${STAGE_ONLY_DIR}"
  # Use a deterministic, absolute path so the Jenkinsfile can pass the same
  # path to kaniko's --context flag without round-tripping through stdout.
  BUILD_CTX="$(cd "${STAGE_ONLY_DIR}" && pwd)"
  echo "==> stage-only mode; context = ${BUILD_CTX} (caller owns cleanup)"
else
  BUILD_CTX="$(mktemp -d -t nova-ci-build.XXXXXX)"
  trap 'rm -rf "${BUILD_CTX}"' EXIT
fi

echo "==> staging build context in ${BUILD_CTX}"
cp "${REPO_ROOT}/ci/Dockerfile" "${BUILD_CTX}/Dockerfile.base"
# Buildroot .config + static rootfs overlay are COPYed into the image by the
# Dockerfile; stage them next to it so they live inside the docker build
# context (we don't want to use REPO_ROOT as the context since that would
# upload the entire kernel tree).
cp "${REPO_ROOT}/ci/buildroot.config" "${BUILD_CTX}/buildroot.config"
cp -a "${REPO_ROOT}/ci/overlay" "${BUILD_CTX}/overlay"

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
    # JFrog returns {"children":[{"uri":"/X.Y.Z","folder":true},...]}.
    # We don't ship a real JSON parser dependency here -- the Jenkins
    # jnlp container is minimal and may have neither python3 nor jq --
    # so pull the version strings out with grep + sort -V instead.
    # `sort -V` is GNU coreutils (always present on the Linux Blossom
    # nodes and on recent macOS).
    COLOSSUS_VERSION="$(curl -sf "${CURL_AUTH[@]}" "${ARTI_API}/" \
      | tr ',' '\n' \
      | grep -oE '"uri"[[:space:]]*:[[:space:]]*"/[0-9][0-9.]*"' \
      | sed -E 's|.*"/([0-9.]+)".*|\1|' \
      | sort -V \
      | tail -1)"
    if [[ -z "${COLOSSUS_VERSION}" ]]; then
      echo "ERROR: could not parse a colossus version from ${ARTI_API}/" >&2
      exit 1
    fi
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

if [[ -n "${STAGE_ONLY_DIR}" ]]; then
  echo
  echo "Context staged at ${BUILD_CTX}. Files:"
  ls -la "${BUILD_CTX}"
  echo
  echo "Hand off to kaniko, e.g.:"
  echo "  /kaniko/executor --context=dir://${BUILD_CTX} --dockerfile=${BUILD_CTX}/Dockerfile --destination=${IMAGE}"
  # Emit the resolved image reference on the very last line so callers can
  # grab it with `tail -n1` without parsing log noise above.
  echo "${IMAGE}"
  exit 0
fi

echo "==> docker build --platform ${PLATFORM} -t ${IMAGE}"
# Use buildx so cross-platform builds work transparently on Apple Silicon (QEMU
# binfmt is shipped with Docker Desktop). Load result into the local image
# store so the smoke check below can run it. Build context is the staging dir
# only -- the generated Dockerfile inlines ci/Dockerfile's content and copies
# only colossus-cli.tar.gz (already staged), so we don't need the repo root.
#
# Caveat: QEMU-emulated kbuild in the buildroot pre-build step trips a known
# GNU-make jobserver inheritance bug in linux-headers' headers_install
# `__sub-make` -- the build dies with "write jobserver: Bad file descriptor"
# after ~3 hours of host-tools compile. For reliable image builds, drive
# ci/Jenkinsfile.image (kaniko on a real x86 Linux node) instead.
"${DOCKER}" buildx build \
  --pull \
  --platform "${PLATFORM}" \
  --load \
  -t "${IMAGE}" \
  "${BUILD_CTX}"

echo "==> smoke check (toolchain + pre-built buildroot tree)"
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
  # The pre-built buildroot must produce a usable rootfs.cpio at image build
  # time; if it does not, the image is broken and the CI Build stage will be
  # back to a 30-min cold cache.
  test -f /opt/buildroot-out/images/rootfs.cpio \
    && echo "rootfs.cpio: $(stat -c "%n %s bytes" /opt/buildroot-out/images/rootfs.cpio)" \
    || { echo "FAIL: /opt/buildroot-out/images/rootfs.cpio missing" >&2; exit 1; }
  # The static overlay (firmware, ssh key, test scripts) must be present and
  # baked into the rootfs by the pre-build.
  test -f /opt/nova-overlay/root/.ssh/authorized_keys \
    || { echo "FAIL: /opt/nova-overlay/root/.ssh/authorized_keys missing" >&2; exit 1; }
  test -d /opt/nova-overlay/usr/lib/firmware/nvidia/ga102 \
    || { echo "FAIL: /opt/nova-overlay/usr/lib/firmware/nvidia/ga102 missing" >&2; exit 1; }
  echo "nvidia firmware dirs: $(ls /opt/nova-overlay/usr/lib/firmware/nvidia | wc -l)"
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
