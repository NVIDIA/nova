# Nova kernel CI agent — Blossom Jenkins `nova-ci` container — public base layer.
# To build + push the full image (this base + the private colossus layer), run:
#   ci/build-image.sh --push                   # tag = today (YYYY-MM-DD)
#   ci/build-image.sh --push --tag 2026-05-13  # explicit tag
# Optional build-args (passed through by the script):
#   TAP_SUMMARY_GIT_SHA=<commit> — pin pcolby/tap-summary summary.gawk (default below).
#   BUILDROOT_REPO / BUILDROOT_BRANCH — Nova Buildroot fork (default: espeer/buildroot, nova-test).
#   BUILDROOT_GIT_SHA=<commit> — if set, full clone then checkout this SHA (else shallow clone of branch).
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

# Colossus CLI is internal and added on top by ci/build-image.sh:
#   COPY --chmod=0755 colossus /usr/local/bin/colossus
# The Jenkinsfile expects `colossus` on PATH for Provision.

WORKDIR /workspace
