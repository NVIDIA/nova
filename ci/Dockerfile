# Nova kernel CI agent — Blossom Jenkins `nova-ci` container.
# Build (from repo root): docker build -f ci/Dockerfile -t YOUR_REGISTRY/nova-kernel-ci:TAG .
# Optional build-args:
#   TAP_SUMMARY_GIT_SHA=<commit> — pin pcolby/tap-summary summary.gawk (default below).
#   BUILDROOT_REPO / BUILDROOT_BRANCH — Nova Buildroot fork (default: espeer/buildroot, nova-test).
#   BUILDROOT_GIT_SHA=<commit> — if set, full clone then checkout this SHA (else shallow clone of branch).
# Push per your registry (e.g. gitlab-master container registry, urm.nvidia.com — see internal docs).
#
# Buildroot *sources* live in /opt/buildroot; Jenkins sets BUILDROOT_OUT (e.g. /scratch/buildroot-out) and runs:
#   make -C /opt/buildroot O=/scratch/buildroot-out
#
# The Jenkins pod runs as a non-root NIS uid; toolchains live in system paths or /opt with a+rx.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    make \
    pkg-config \
    build-essential \
    bc \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    libncurses-dev \
    dwarves \
    pahole \
    cpio \
    kmod \
    rsync \
    zip \
    unzip \
    xz-utils \
    zlib1g-dev \
    clang \
    lld \
    llvm \
    libclang-dev \
    ccache \
    jq \
    gawk \
    openssh-client \
    python3-minimal \
    binutils \
    && rm -rf /var/lib/apt/lists/*

# TAP summary script (pcolby/tap-summary, MIT): fetch at image build so agents need no runtime download.
# Upstream: https://github.com/pcolby/tap-summary
ARG TAP_SUMMARY_GIT_SHA=ec9de3f6393083dd89052d519a23b2999a75be9b
RUN mkdir -p /usr/local/share/nova-ci \
    && curl -fsSL -o /usr/local/share/nova-ci/tap-summary.gawk \
        "https://raw.githubusercontent.com/pcolby/tap-summary/${TAP_SUMMARY_GIT_SHA}/summary.gawk" \
    && chmod a+r /usr/local/share/nova-ci/tap-summary.gawk

# Rust (Rust for Linux): install under /opt so any runAsUser can read/execute.
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y \
      --no-modify-path \
      --default-toolchain none \
    && "${CARGO_HOME}/bin/rustup" toolchain install nightly -c rust-src -c rustfmt -c clippy \
    && "${CARGO_HOME}/bin/rustup" default nightly \
    && chmod -R a+rX "${RUSTUP_HOME}" "${CARGO_HOME}"

ENV PATH="${CARGO_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Nova Buildroot fork (branch carries .config). Output dir is O= on NFS in Jenkins, not under /opt.
ARG BUILDROOT_REPO=https://github.com/espeer/buildroot.git
ARG BUILDROOT_BRANCH=nova-test
ARG BUILDROOT_GIT_SHA=
RUN set -eux; \
    if [ -n "${BUILDROOT_GIT_SHA}" ]; then \
      git clone "${BUILDROOT_REPO}" /opt/buildroot; \
      git -C /opt/buildroot checkout -q "${BUILDROOT_GIT_SHA}"; \
    else \
      git clone --depth 1 --branch "${BUILDROOT_BRANCH}" "${BUILDROOT_REPO}" /opt/buildroot; \
    fi; \
    chmod -R a+rX /opt/buildroot; \
    rm -rf /opt/buildroot/.git

# Colossus CLI is internal — add in a private image layer, e.g.:
#   COPY --chmod=0755 colossus /usr/local/bin/colossus
# The Jenkinsfile expects `colossus` on PATH for Provision.

WORKDIR /workspace
