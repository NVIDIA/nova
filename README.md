# Nova Test Branch (`nova-test`)

Welcome to the **nova-test** branch.

### Purpose
The primary purpose of this branch is to provide a stable, automated environment for testing [**Nova**](https://rust-for-linux.com/nova-gpu-driver) GPU driver kernel patches destined for upstream Linux.

Every Pull Request opened against this branch triggers a test suite executed on a cluster of **NVIDIA GPU hardware**. This allows Nova developers to validate drivers on real silicon before upstream submission to `drm-rust-next`.

---

## Branch Maintenance & Architecture

The `nova-test` branch is a dynamically maintained branch that combines the latest upstream work with our custom testing infrastructure.

### The Nightly Sync
To ensure we are always testing against the freshest code, a nightly automation process performs the following:
1. **Sync:** Resets the branch to the latest [`drm-rust-next`](https://gitlab.freedesktop.org/drm/rust/kernel/-/tree/drm-rust-next) upstream head.
2. **Infrastructure Overlay:** Cherry-picks the commits from the [`test-infra`](https://github.com/NVIDIA/nova/tree/test-infra) branch. That branch holds GitHub Action workflows, kernel configurations, helper scripts, and related CI definitions.
3. **Result:** A clean, updated `nova-test` branch that is ready for the next day's patch testing.

### The Test Environment (`buildroot`)
We leverage [**buildroot**](https://github.com/espeer/buildroot/tree/nova-test) to define the userspace environment for tests.

* **Minimalism:** Buildroot creates a minimal `initrd` and `kexec` kernel used to boot the hardware targets.
* **Test Suite Definition:** The actual functional test cases and the version of the test harness are presently defined within this buildroot repository. The tests will get separated into their own repository in due course, as the test suite matures. The intent is to eventually leverage the internal test suite utilized for testing the existing NVIDIA driver suite, including [Open GPU](https://github.com/NVIDIA/open-gpu-kernel-modules), once Nova is capable of running it.
* **Consistency:** By decoupling the test infrastructure from the kernel source, we ensure that the environment remains consistent even as the kernel under test changes.

---

## How to Submit Patches for Testing

Follow these steps to run your patches through the Nova hardware test pipeline.

### 1. Prepare your environment

Use a clone that has **`NVIDIA/nova`** as a remote (many checkouts name it **`public`**) and your **fork** (e.g. **`espeer/nova`**) as a second push remote.

Keep **`nova-test`** aligned with upstream, then branch or rebase your work:

```bash
git fetch public nova-test
git checkout nova-test
git reset --hard public/nova-test

git checkout my-feature-test
git rebase nova-test
```

If you are creating a new branch from current `nova-test`:

```bash
git fetch public nova-test
git checkout -b my-feature-test public/nova-test
```

### 2. Apply your patches

Apply your work-in-progress patches using your method of choice (`b4`, `git am`, `git merge`, etc).
For example, `b4` can be used to grab a patchset from a mailing list:

```bash
b4 shazam "<20251203055923.1247681-1-jhubbard@nvidia.com>"
```

Such patches should apply cleanly if they are based on current `drm-rust-next`. The only other patches carried in `nova-test` are isolated test infrastructure files that should never conflict.

### 3. Create a Pull Request

Push your branch to **your fork** (`espeer/nova` or whichever GitHub account owns the fork), then open a PR against **`NVIDIA/nova`**:

```bash
git push --force-with-lease nova-fork my-feature-test
gh pr create --repo NVIDIA/nova --base nova-test --head espeer:my-feature-test \
  --title "Your descriptive PR title" \
  --body "Detailed description of patches being applied (e.g., link to mailing list thread)."
```

Replace **`nova-fork`** with whatever remote name points at `git@github.com:espeer/nova.git` (add it once with `git remote add nova-fork git@github.com:espeer/nova.git` if needed).

See **closed pull requests** on [`NVIDIA/nova`](https://github.com/NVIDIA/nova/pulls?q=is%3Apr+is%3Aclosed) for examples against `nova-test`.

---

## Workflows and CI

### GitHub Actions
Automation includes workflows under `.github/workflows/` (carried via the `test-infra` branch):

* **[test.yml](https://github.com/NVIDIA/nova/blob/nova-test/.github/workflows/test.yml)**: Triggered on Pull Requests to `nova-test` where enabled; coordinates builds, hardware interaction, and TAP reporting where applicable.
* **[update.yml](https://github.com/NVIDIA/nova/blob/nova-test/.github/workflows/update.yml)**: Nightly sync to `drm-rust-next` and cherry-picks from `test-infra`.

### Blossom (Jenkins)
Internal **Blossom** jobs may use the root **`Jenkinsfile`** and **`ci/Dockerfile`** (container image for the `nova-ci` agent). Details live in comments in those files and in internal NVIDIA docs.

---

## Important Notes
* **Hardware Availability:** Tests run on real hardware. Depending on cluster load, there may be a delay before your jobs start.
* **Branch Volatility:** Because `nova-test` is rebased nightly, it is a **non-stable, force-pushed branch**. It is inadvisable to base long-lived work on `nova-test` by tracking this branch; use it only as a target for PRs that apply cleanly against `drm-rust-next`.
* **Merges:** By similar token, we do not accept or merge PRs into the `nova-test` branch.
* **External Collaboration:** Due to the security model pertaining to self-hosted GitHub Action runners (and related internal CI), we currently do not permit PRs from external collaborators. We intend to revisit this security policy later, depending on external demand and the investment required to make it safe to do so.
