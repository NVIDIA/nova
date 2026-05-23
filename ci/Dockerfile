# Nova kernel CI agent — Blossom Jenkins `nova-ci` container — public base layer.
#
# This Dockerfile is consumed two ways:
#   1. Inline in the main Jenkins pipeline: the Phase 1 "Ensure agent image"
#      stage hashes ci/image-manifest + listed inputs, probes the registry,
#      and on a miss runs kaniko against this Dockerfile with --build-args
#      taken from the manifest's pin lines.
#   2. Local developer builds via ci/build-image.sh (docker buildx; reads
#      the same manifest for pin defaults).
#
# Required build-args (NO defaults; image build fails closed without them
# so a missing pin is a loud error rather than a silently-floating image):
#   BUILDROOT_TAG=<tag>            — upstream buildroot tag (pinned in
#                                    ci/image-manifest as buildroot_tag).
#   LINUX_FIRMWARE_GIT_SHA=<sha>   — pin upstream linux-firmware (pinned in
#                                    ci/image-manifest as linux_firmware_sha).
# Optional build-arg:
#   TAP_SUMMARY_GIT_SHA=<commit>   — pin pcolby/tap-summary summary.gawk.
#
# Buildroot *sources* live in /opt/buildroot; the build is pre-staged in the
# image at /opt/buildroot-out (host + target packages, rootfs staging, etc.).
# Per-CI runs only install the freshly-built kernel modules into
# /opt/buildroot-out/modules/ and re-pack rootfs.cpio — orders of magnitude
# faster than the cold-cache 30-min run we used to get every CI run.
#
# The static rootfs overlay (ssh authorized_keys, avocado test definitions,
# resolv.conf symlink) lives at ci/overlay/ in this repo and is COPIED into
# /opt/nova-overlay. NVIDIA firmware is fetched from upstream linux-firmware
# (nvidia/ subtree only, sparse-checkout) and dropped under
# /opt/nova-overlay/usr/lib/firmware/nvidia/ (merged-/usr layout; buildroot's
# target-finalize overlay sanity check rejects a top-level /lib). That single
# overlay path is
# already baked into the pre-built rootfs at image-build time. At CI time
# the Jenkinsfile re-adds ${BUILDROOT_OUT}/modules alongside it before
# repacking the cpio.
#
# The Jenkins pod runs as a non-root NIS uid; toolchains live in system paths
# or /opt with a+rx, and /opt/buildroot-out is chmod a+rwX so the runtime uid
# can mutate it via the container's writable upper layer (no NFS, no clock
# skew, no emptyDir needed).

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    make \
    patch \
    pkg-config \
    build-essential \
    bc \
    bison \
    flex \
    file \
    bzip2 \
    perl \
    which \
    libssl-dev \
    libelf-dev \
    libdw-dev \
    libncurses-dev \
    dwarves \
    pahole \
    cpio \
    kmod \
    rsync \
    zip \
    unzip \
    xz-utils \
    zstd \
    zlib1g-dev \
    clang \
    lld \
    llvm \
    libclang-dev \
    ccache \
    jq \
    gawk \
    openssh-client \
    libnss-wrapper \
    python3 \
    binutils \
    time \
    && rm -rf /var/lib/apt/lists/*

# TAP summary script (pcolby/tap-summary, MIT): fetch at image build so agents need no runtime download.
# Upstream: https://github.com/pcolby/tap-summary
ARG TAP_SUMMARY_GIT_SHA=ec9de3f6393083dd89052d519a23b2999a75be9b
RUN mkdir -p /usr/local/share/nova-ci \
    && curl -fsSL -o /usr/local/share/nova-ci/tap-summary.gawk \
        "https://raw.githubusercontent.com/pcolby/tap-summary/${TAP_SUMMARY_GIT_SHA}/summary.gawk" \
    && chmod a+r /usr/local/share/nova-ci/tap-summary.gawk

# Rust (Rust for Linux): install under /opt so any runAsUser can read/execute.
# bindgen-cli is the *separate* host-side binary that kbuild's
# scripts/rust_is_available.sh probes via `bindgen --version`. Without
# it, that script exits non-zero, `make rustavailable` returns failure,
# and kconfig silently flips CONFIG_RUST to n -- which in turn hides
# every `depends on RUST` symbol (CONFIG_NOVA_CORE, CONFIG_DRM_NOVA, ...).
# Build #65 reproduced this exactly: nova.ko/nova-core.ko were never
# emitted, modules_install completed with no nova modules, and the
# kexec'd target had no driver to load. Pinned to "latest" per user
# direction -- accept that a future bindgen API break may require a
# version-pin retrofit (see scripts/min-tool-version.sh bindgen for
# the kernel-required lower bound).
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y \
      --no-modify-path \
      --default-toolchain none \
    && "${CARGO_HOME}/bin/rustup" toolchain install nightly -c rust-src -c rustfmt -c clippy \
    && "${CARGO_HOME}/bin/rustup" default nightly \
    && "${CARGO_HOME}/bin/cargo" install --locked bindgen-cli \
    && chmod -R a+rX "${RUSTUP_HOME}" "${CARGO_HOME}"

ENV PATH="${CARGO_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Buildroot: upstream tag, no local fork ---
# Pre-2026-05-22 we cloned espeer/buildroot:nova-test, whose only delta from
# upstream 2025.08.2 was a single commit adding .config. We now pin to the
# upstream tag and bake the same .config from this repo (ci/buildroot.config).
# Required build-arg from ci/image-manifest (buildroot_tag=). No default
# value: a missing --build-arg fails the clone step loudly rather than
# silently producing a "whatever main was today" image.
ARG BUILDROOT_TAG
RUN test -n "${BUILDROOT_TAG}" || (echo "ERROR: BUILDROOT_TAG --build-arg is required (pin lives in ci/image-manifest)" >&2 && exit 1)
RUN git clone --depth 1 --branch "${BUILDROOT_TAG}" \
        https://gitlab.com/buildroot.org/buildroot.git /opt/buildroot \
 && chmod -R a+rX /opt/buildroot \
 && rm -rf /opt/buildroot/.git

# --- Static rootfs overlay (no firmware here; that comes from linux-firmware below) ---
# Staged into the build context by ci/build-image.sh from ci/overlay/.
# COPY preserves only the source mtime + the executable bit (git's record
# doesn't carry finer modes), so the authorized_keys file lands at the
# tarball-default 0644 unless we override here. sshd / ssh both refuse
# authorized_keys with group-or-other read permission ("bad ownership or
# modes for file ..."), and the `~/.ssh` dir similarly must be 0700; the
# pre-#64 false-pass was triggered partly by this. Fix the modes the
# moment the overlay lands so the per-CI buildroot rsync into the
# rootfs preserves them (rsync -a copies permissions verbatim).
COPY overlay /opt/nova-overlay
RUN chmod 0700 /opt/nova-overlay/root/.ssh \
 && chmod 0600 /opt/nova-overlay/root/.ssh/authorized_keys

# --- NVIDIA firmware: sparse-clone nvidia/ from upstream linux-firmware ---
# Cone-mode sparse-checkout + --filter=blob:none fetches only blobs reachable
# from the nvidia/ subtree (~600 MB) instead of the full ~12 GB tree. The
# resulting nvidia/ dir is dropped under /opt/nova-overlay/usr/lib/firmware/.
#
# Path must be /usr/lib/firmware (not /lib/firmware): buildroot enforces
# BR2_ROOTFS_MERGED_USR (default since 2022.05) and target-finalize's overlay
# sanity check errors out with "not using a merged /usr for the following
# directories: /lib" if we put a top-level /lib in the overlay. The target
# image still resolves /lib/firmware/nvidia/* at runtime because /lib is a
# symlink to /usr/lib in the merged-usr layout.
#
# Required build-arg from ci/image-manifest (linux_firmware_sha=). No default
# value: bumping the manifest pin is the only supported way to refresh the
# firmware blobs in the agent image. Image build fails closed without it.
ARG LINUX_FIRMWARE_GIT_SHA
RUN set -eux; \
    test -n "${LINUX_FIRMWARE_GIT_SHA}" || (echo "ERROR: LINUX_FIRMWARE_GIT_SHA --build-arg is required (pin lives in ci/image-manifest)" >&2 && exit 1); \
    git clone --no-checkout --no-tags --filter=blob:none --sparse \
        https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
        /tmp/lf; \
    git -C /tmp/lf fetch --depth 1 origin "${LINUX_FIRMWARE_GIT_SHA}"; \
    git -C /tmp/lf checkout -q "${LINUX_FIRMWARE_GIT_SHA}"; \
    git -C /tmp/lf sparse-checkout set --cone nvidia; \
    mkdir -p /opt/nova-overlay/usr/lib/firmware; \
    cp -a /tmp/lf/nvidia /opt/nova-overlay/usr/lib/firmware/nvidia; \
    rm -rf /tmp/lf

# --- Pre-build buildroot in the image ---
# Buildroot refuses to run as root. Create a builder user, hand it the source
# tree + a pre-resolved .config from this repo, and run the full make. The
# pre-built tree contains host tools (host-cmake, host-rust-bin, host-gcc
# bootstrap, ...) + target packages (busybox, openssh, systemd, avocado, ...)
# + a complete rootfs.cpio that already has the static overlay (firmware +
# ssh key + test scripts) baked in. CI runs only repack the cpio after
# installing the freshly-built kernel modules into /opt/buildroot-out/modules.
COPY buildroot.config /opt/buildroot-out/.config
# Ubuntu 24.04 already ships a group at GID 30 (`tape`), so we skip
# `groupadd` and let `useradd -g 30` reference it directly. The CI
# pod's RUN_AS_GID=30 is what we actually care about; the group's
# *name* in this image is irrelevant.
RUN sed -i 's|^BR2_ROOTFS_OVERLAY=.*|BR2_ROOTFS_OVERLAY="/opt/nova-overlay"|' \
        /opt/buildroot-out/.config \
 && useradd -m -u 9999 -g 30 builder \
 && chown -R builder:30 /opt/buildroot /opt/buildroot-out /opt/nova-overlay
# /opt/nova-overlay is chowned to builder so buildroot's rsync (which runs
# as builder) can read into /root/.ssh -- that dir is mode 0700 to satisfy
# sshd on the target. The mode bits are preserved verbatim by rsync; the
# final ownership in the cpio is fixed up by buildroot's fakeroot/devtable
# pass, so chowning the source to builder doesn't leak into the target
# rootfs (the cpio's /root/.ssh ends up root:root 0700 either way).
USER builder
WORKDIR /opt/buildroot
RUN make O=/opt/buildroot-out olddefconfig \
 && make O=/opt/buildroot-out -j"$(nproc)"
USER root
WORKDIR /workspace

# Make the pre-built tree mutable by any uid: CI runs as a NIS uid (e.g.
# 150707) and must be able to write modules + rootfs.cpio into the container's
# writable upper layer. /opt/nova-overlay stays read-mostly (overlay rsync
# only reads), but be permissive in case a future change writes to it.
RUN chmod -R a+rwX /opt/buildroot-out /opt/nova-overlay

# Colossus CLI is internal and added on top by ci/build-image.sh:
#   COPY --chmod=0755 colossus /usr/local/bin/colossus
# The Jenkinsfile expects `colossus` on PATH for Provision.

WORKDIR /workspace
