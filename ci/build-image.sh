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
#   ci/build-image.sh                          # build only, tag = image-<sha12> from manifest
#   ci/build-image.sh --push                   # build + docker push
#   ci/build-image.sh --tag image-deadbeef0123 # explicit tag (overrides manifest hash)
#   ci/build-image.sh --push --tag image-deadbeef0123
#
# Usage (Jenkins / kaniko -- stage the build context but do not invoke docker):
#   ci/build-image.sh --stage-only DIR --tag image-deadbeef0123
#       writes Dockerfile + buildroot.config + overlay/ + colossus-cli.tar.gz
#       into DIR, ready for `kaniko --context=dir://DIR --dockerfile=DIR/Dockerfile`.
#       Skips the `docker buildx build`, the smoke check, and the push.
#
# Pin resolution: BUILDROOT_TAG, LINUX_FIRMWARE_GIT_SHA, TAP_SUMMARY_GIT_SHA,
# COLOSSUS_VERSION, RUN_AS_UID and RUN_AS_GID default to the values pinned in
# ci/image-manifest. They can be overridden via environment variable when
# iterating locally (e.g. to test a newer linux-firmware sha before updating
# the pin). All but COLOSSUS_VERSION are passed through as --build-arg to
# docker buildx / kaniko; COLOSSUS_VERSION instead drives the colossus tarball
# download and the private-layer COPY in the generated Dockerfile.
#
# Environment overrides:
#   REGISTRY            gitlab-master.nvidia.com:5005
#   REPO                epeer/nova-test/nova-kernel-ci
#   BUILDROOT_TAG       upstream buildroot tag (default: manifest pin).
#   LINUX_FIRMWARE_GIT_SHA  linux-firmware commit sha (default: manifest pin).
#   TAP_SUMMARY_GIT_SHA pcolby/tap-summary summary.gawk commit (default: manifest pin).
#   COLOSSUS_VERSION    Colossus CLI version to install (default: manifest pin).
#   RUN_AS_UID          uid for the in-image `builder` user; matches the
#                       CI pod's runAsUser so the pre-built buildroot tree
#                       can be mutated at CI time (default: manifest pin).
#   RUN_AS_GID          primary gid for `builder` (default: manifest pin).
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
#                       prefer pushing to nova-test and letting the main
#                       pipeline's Phase 1 kaniko build run on a real x86 node).

set -euo pipefail

REGISTRY="${REGISTRY:-gitlab-master.nvidia.com:5005}"
REPO="${REPO:-epeer/nova-test/nova-kernel-ci}"
DOCKER="${DOCKER:-docker}"
PLATFORM="${PLATFORM:-linux/amd64}"
ARTIFACTORY_HOST="${ARTIFACTORY_HOST:-artifactory.nvidia.com}"
ARTIFACTORY_REPO="${ARTIFACTORY_REPO:-sw-ipp-colossus-generic}"
ARTIFACTORY_USER="${ARTIFACTORY_USER:-${USER:-}}"

TAG=""
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
      # Print the leading comment header (everything from the line after the
      # shebang down to the first non-comment line), stripping the "# " prefix.
      # Driven off the comment block itself so it can't drift out of sync with
      # the header's length the way a hardcoded line range did.
      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} /^[[:space:]]*$/{print;next} {exit}' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "${STAGE_ONLY_DIR}" && "${PUSH}" -eq 1 ]]; then
  echo "--stage-only and --push are mutually exclusive (kaniko does the push)" >&2
  exit 2
fi

CI_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${CI_DIR}/image-manifest"
REPO_ROOT="$(cd "${CI_DIR}/.." && pwd)"

# Read pins from ci/image-manifest. Each KEY=VALUE line that isn't an
# `input=` and isn't a comment exports MANIFEST_<key>. Env vars override
# the manifest (useful for local "test this newer sha before bumping
# the pin" iterations).
if [[ ! -f "${MANIFEST}" ]]; then
  echo "ERROR: ${MANIFEST} not found; cannot resolve build pins" >&2
  exit 1
fi
manifest_pin() {
  # $1 = key (e.g. buildroot_tag). Echoes the value or empty.
  awk -F= -v k="$1" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    $1 == "input"   { next }
    $1 == k         { sub(/^[^=]*=/, ""); sub(/[[:space:]]+$/, ""); print; exit }
  ' "${MANIFEST}"
}
: "${BUILDROOT_TAG:=$(manifest_pin buildroot_tag)}"
: "${LINUX_FIRMWARE_GIT_SHA:=$(manifest_pin linux_firmware_sha)}"
: "${TAP_SUMMARY_GIT_SHA:=$(manifest_pin tap_summary_sha)}"
: "${COLOSSUS_VERSION:=$(manifest_pin colossus_version)}"
: "${RUN_AS_UID:=$(manifest_pin run_as_uid)}"
: "${RUN_AS_GID:=$(manifest_pin run_as_gid)}"
for v in BUILDROOT_TAG LINUX_FIRMWARE_GIT_SHA TAP_SUMMARY_GIT_SHA COLOSSUS_VERSION RUN_AS_UID RUN_AS_GID; do
  if [[ -z "${!v}" ]]; then
    echo "ERROR: ${v} is empty after manifest resolution; check ${MANIFEST}" >&2
    exit 1
  fi
done

# Default tag: image-<sha12> from hash-inputs.sh. The hash script is the
# canonical algorithm; we never re-implement it here. Both the Jenkinsfile
# and this script call it, so a `--tag` default from this script matches
# the tag the pipeline would probe -- letting a local `--push` populate
# the registry for a later CI run on the same inputs.
if [[ -z "${TAG}" ]]; then
  HASH="$("${CI_DIR}/hash-inputs.sh")"
  TAG="image-${HASH}"
  echo "==> derived tag from manifest hash: ${TAG}"
fi

IMAGE="${REGISTRY}/${REPO}:${TAG}"

echo "==> target image:  ${IMAGE}"
echo "==> repo root:     ${REPO_ROOT}"
echo "==> pins:"
echo "      buildroot_tag       = ${BUILDROOT_TAG}"
echo "      linux_firmware_sha  = ${LINUX_FIRMWARE_GIT_SHA}"
echo "      colossus_version    = ${COLOSSUS_VERSION}"

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
  # COLOSSUS_VERSION is already resolved from ci/image-manifest above
  # (with env override). The previous "auto-discover latest from
  # artifactory" path is gone -- floating to "whatever artifactory has
  # today" defeats the whole point of content-addressed images.
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
    echo "RUN set -eu; \\"
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
  echo "  /kaniko/executor --context=dir://${BUILD_CTX} --dockerfile=${BUILD_CTX}/Dockerfile \\"
  echo "    --build-arg BUILDROOT_TAG=${BUILDROOT_TAG} \\"
  echo "    --build-arg LINUX_FIRMWARE_GIT_SHA=${LINUX_FIRMWARE_GIT_SHA} \\"
  echo "    --build-arg TAP_SUMMARY_GIT_SHA=${TAP_SUMMARY_GIT_SHA} \\"
  echo "    --build-arg RUN_AS_UID=${RUN_AS_UID} \\"
  echo "    --build-arg RUN_AS_GID=${RUN_AS_GID} \\"
  echo "    --destination=${IMAGE}"
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
# after ~3 hours of host-tools compile. For reliable image builds, push to
# nova-test and let the main pipeline's Phase 1 stage kaniko-build the image
# on a real x86 Linux node instead.
"${DOCKER}" buildx build \
  --pull \
  --platform "${PLATFORM}" \
  --load \
  --build-arg "BUILDROOT_TAG=${BUILDROOT_TAG}" \
  --build-arg "LINUX_FIRMWARE_GIT_SHA=${LINUX_FIRMWARE_GIT_SHA}" \
  --build-arg "TAP_SUMMARY_GIT_SHA=${TAP_SUMMARY_GIT_SHA}" \
  --build-arg "RUN_AS_UID=${RUN_AS_UID}" \
  --build-arg "RUN_AS_GID=${RUN_AS_GID}" \
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
  echo "The main pipeline auto-discovers this tag: Phase 1 hashes ci/image-manifest"
  echo "+ inputs and, on its next run for these same inputs, the registry probe"
  echo "hits this tag and skips the kaniko rebuild. No Jenkinsfile edit needed."
else
  echo
  echo "Built ${IMAGE} (not pushed; pass --push to push)."
fi
