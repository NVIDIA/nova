// Nova CI on Blossom — GitHub PR webhook + Colossus hardware tests.
//
// Blossom note: Jenkins resolves this Jenkinsfile from the job's pinned ref on
// https://github.com/NVIDIA/nova (e.g. nova-test), not from open PR branches.
// Merge pipeline changes to that ref before a PR build will run them; the PR
// checkout still supplies the kernel tree under test. A separate privileged
// "Jenkinsfile from PR" job can be added later if needed.
//
// Prerequisites (Blossom / your team):
// - Global Pipeline Library: blossom-github-lib (blossom-github-jenkins-lib on GitLab)
// - Credential id "github-token" (PAT in password field)
// - Generic Webhook Trigger: post param githubData = JSONPath "$"
// - Shared scratch on NFS (ccache + ephemeral Buildroot O= output): follow Blossom how-to (NIS uid/gid + nfs volume):
//   https://nvidia.atlassian.net/wiki/spaces/BLOS/pages/2147264305/NFS+scratch+space+for+Blossom+Jenkins+job
//   Export: ipp1-cdot01-col01:/vol/scratch1/scratch.epeer_blossom → mountPath /scratch
//   Set job parameters RUN_AS_UID / RUN_AS_GID from `id` on a Linux host (same as wiki Step 3–4).
// - TAP summary: GNU gawk + /usr/local/share/nova-ci/tap-summary.gawk (from ci/Dockerfile).
// - CI image: see ci/Dockerfile — clang/llvm, ccache, make, git, colossus CLI (add in private layer),
//   jq, curl, openssh-client, Rust-for-Linux (rustup nightly + rust-src / rustfmt / clippy), etc.
//   Avocado runs only on the leased test target (Buildroot initrd), not on this agent.
// - Buildroot: sources baked into CI image at /opt/buildroot (espeer/buildroot nova-test); NFS holds
//   /scratch/buildroot-out (make O=...) and /scratch/ccache — safe to delete; outputs regenerate.
// - Colossus auth: Starfleet Service Account (SSA). Add a "Username with password"
//   Jenkins credential with id "colossus-ssa" -- username = SSA client_id, password =
//   client_secret. The "Colossus login" stage below runs `colossus login --method ssa`
//   once per pipeline; the resulting token persists on the nova-ci container's local
//   FS for the rest of the run (Provision + finally cleanup). Manual `colossus login`
//   (OIDC/LDAP) is deprecated and will not work non-interactively. Onboarding SOP:
//   https://confluence.nvidia.com/display/Colossus/SSA+Clients+on-boarding+with+Colossus
// - CI image default is public GitLab Container Registry (no imagePullSecrets). If the image
//   becomes private, add a K8s docker-registry pull secret (namespace SA or pod spec) or reintroduce
//   imagePullSecrets in the pod yaml below.
// - podTemplate omits yamlMergeStrategy: PodYamlMergeStrategy is not on the workflow Groovy
//   classpath on this controller (CPS sandbox throws MissingPropertyException: org). The
//   Kubernetes plugin merges inline yaml with containerTemplate by default.
// - jnlp keeps the image's default uid 1000 (overriding it makes jnlp crash with
//   AccessDeniedException: /home/jenkins/agent -- whatever the image's entrypoint does to the
//   volume mount only works as the built-in jenkins user). We only override runAsGroup=30 and
//   the command, so jnlp's process runs uid 1000 gid 30 with umask 0002 -- new dirs come out
//   mode 0775 owned 1000:30 instead of 0755 1000:1000. nova-ci (uid 150707 gid 30) can then
//   write into them via group permission. This is the root cause of the durable-task exit -2
//   we hit through #31..#38: jnlp created workspace/nova-cicd@tmp/ at 0755 jenkins:jenkins, so
//   nova-ci could not drop jenkins-log.txt / pid into durable-XXX/ -- the wrapper exited before
//   producing any output and durable-task reported "process apparently never started".
// - No fsGroup: kubelet applies fsGroup to "nfs" volumes too, which would trigger a chown over
//   the /scratch NFS export. The export is root-squashed, so kubelet's chown maps to nobody on
//   the server (the export is owned 150707:30, not root) -- so fsGroup would either fail pod
//   startup or log a noisy kubelet warning, depending on fsGroupChangePolicy. Same-gid in both
//   containers plus jnlp umask 0002 solves the workspace problem cleanly without touching NFS.

@Library('blossom-github-lib@master')
import ipp.blossom.*

properties([
  parameters([
    string(name: 'RUN_AS_UID', defaultValue: '150707', description: 'NIS uid for pod + NFS /scratch (Blossom scratch how-to); override if not epeer'),
    string(name: 'RUN_AS_GID', defaultValue: '30', description: 'Primary NIS gid for pod + NFS /scratch; override if your export differs'),
    string(name: 'ANSIBLE_GIT_URL', defaultValue: 'https://gitlab-master.nvidia.com/epeer/nova-test.git', description: 'Git URL passed to colossus bm lease -agu (Ansible playbooks)'),
    string(name: 'ANSIBLE_GIT_BRANCH', defaultValue: 'main', description: 'Branch for -agb (playbook / lease metadata; epeer/nova-test on GitLab)'),
    string(name: 'ANSIBLE_PLAYBOOK', defaultValue: 'target.yml', description: 'Playbook path in repo for -apb'),
  ])
])

// CI image tag is intentionally NOT a job parameter: Jenkins persists the
// last-used parameter value and ignores subsequent defaultValue changes in the
// Jenkinsfile, so bumping the tag with a parameter required a manual "Build
// with Parameters" round-trip every time. Keep this as a plain script var so
// every commit that bumps the tag takes effect on the next /build comment.
def ciImage = 'gitlab-master.nvidia.com:5005/epeer/nova-test/nova-kernel-ci:2026-05-19'

def runUid = params.RUN_AS_UID?.trim()
def runGid = params.RUN_AS_GID?.trim()
if (!runUid || !runGid) {
  error('Set job parameters RUN_AS_UID and RUN_AS_GID to your NIS uid/gid from `id` (see Blossom NFS scratch how-to).')
}

// Status updates are inlined per call site (was: postCommitStatus helper method): build #37 had
// an empty Code checkout stage body and never reached Build or the catch block -- the CPS-
// transformed helper method with a typed GitHubCommitState parameter was being dropped silently.
// Inlining sidesteps the helper-method dispatch entirely. We also do not retain a GithubHelper
// instance in a long-lived local across save points (see comment inside the node block below).

podTemplate(
  cloud: 'sc-ipp-blossom-prod',
  yaml: """
apiVersion: v1
kind: Pod
spec:
  volumes:
  - name: scratch
    nfs:
      server: ipp1-cdot01-col01
      path: /vol/scratch1/scratch.epeer_blossom
  nodeSelector:
    kubernetes.io/os: "linux"
  containers:
  - name: jnlp
    command: ["/bin/sh", "-c"]
    args: ["umask 0002 && exec /usr/local/bin/jenkins-agent"]
    securityContext:
      runAsGroup: ${runGid.toInteger()}
    resources:
      requests:
        memory: 1Gi
        cpu: 500m
      limits:
        memory: 2Gi
  - name: nova-ci
    volumeMounts:
    - name: scratch
      mountPath: /scratch
    securityContext:
      runAsUser: ${runUid.toInteger()}
      runAsGroup: ${runGid.toInteger()}
      allowPrivilegeEscalation: false
    resources:
      requests:
        # Reserved per pod -- conservative so the scheduler still places us.
        memory: 16Gi
        cpu: "8"
      limits:
        # Build #46 OOM-killed cc1plus while buildroot was bootstrapping cmake
        # under -j128: at peak the C++ host-tools compile easily wants 80+ GiB.
        # Set a roomy ceiling so this stops being a recurring failure mode.
        memory: 64Gi
        cpu: "64"
""",
  containers: [
    containerTemplate(
      name: 'nova-ci',
      image: ciImage,
      ttyEnabled: true,
      command: 'cat'
    )
  ]
) {
  node(POD_LABEL) {
    // PR/commit metadata captured as plain strings during Get Token. We deliberately do NOT
    // keep a GithubHelper instance in a long-lived local: the helper holds GHCommitStatus
    // references (returned by updateCommitStatus) which are not Serializable, and CPS saves
    // the program state on every step boundary -- a single live helper local causes
    // NotSerializableException: org.kohsuke.github.GHCommitStatus on the next save.
    String buildDescription = ''
    String prNum = ''
    String cloneUrl = ''
    String prState = ''
    String repoName = ''
    boolean tokenAcquired = false
    def stageName = ''

    stage('Get Token') {
      withCredentials([usernamePassword(
        credentialsId: 'github-token',
        passwordVariable: 'GIT_PASSWORD',
        usernameVariable: 'GIT_USERNAME'
      )]) {
        def h = GithubHelper.getInstance("${GIT_PASSWORD}", githubData)
        buildDescription = h.getBuildDescription()
        prNum = h.getPRNumber().toString()
        cloneUrl = h.getCloneUrl()
        prState = h.getPRState()
        repoName = h.getRepoName()
        tokenAcquired = true
      }
    }

    try {
      currentBuild.description = buildDescription

      stageName = 'Code checkout'
      stage(stageName) {
        echo "DIAG: entered ${stageName} body"
        withCredentials([usernamePassword(
          credentialsId: 'github-token',
          passwordVariable: 'GIT_PASSWORD',
          usernameVariable: 'GIT_USERNAME'
        )]) {
          GithubHelper.getInstance("${GIT_PASSWORD}", githubData).updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
        }
        echo "DIAG: posted ${stageName} Running status; preparing shallow checkout"
        echo "DIAG: prNum=${prNum} prState=${prState}"
        def cloneExtensions = [
          [$class: 'CloneOption', shallow: true, depth: 1, noTags: true, honorRefspec: true, timeout: 30],
        ]
        if ('Open'.equalsIgnoreCase(prState)) {
          checkout changelog: true, poll: false, scm: [
            $class: 'GitSCM',
            branches: [[name: "refs/remotes/origin/pr/${prNum}"]],
            extensions: cloneExtensions,
            userRemoteConfigs: [[
              credentialsId: 'github-token',
              url: cloneUrl,
              refspec: "+refs/pull/${prNum}/head:refs/remotes/origin/pr/${prNum}"
            ]]
          ]
        } else if ('Merged'.equalsIgnoreCase(prState)) {
          checkout changelog: true, poll: false, scm: [
            $class: 'GitSCM',
            branches: [[name: "refs/remotes/origin/pr/${prNum}"]],
            extensions: cloneExtensions,
            userRemoteConfigs: [[
              credentialsId: 'github-token',
              url: cloneUrl,
              refspec: "+refs/pull/${prNum}/merge:refs/remotes/origin/pr/${prNum}"
            ]]
          ]
        } else {
          error("PR state '${prState}' is neither Open nor Merged; nothing to check out.")
        }
        echo "DIAG: checkout returned"
      }

      stageName = 'Build'
      stage(stageName) {
        container('nova-ci') {
          withCredentials([usernamePassword(
            credentialsId: 'github-token',
            passwordVariable: 'GIT_PASSWORD',
            usernameVariable: 'GIT_USERNAME'
          )]) {
            GithubHelper.getInstance("${GIT_PASSWORD}", githubData).updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
          }
          withEnv([
            // ccache cache: lives on /scratch (NFS). ccache is content-addressed
            // (keyed by source+flags hash), so file mtime is irrelevant and the
            // NFS clock skew that bites make-based incremental builds is a non-
            // issue here. Cross-pod cache hits are worth the extra latency.
            'CCACHE_DIR=/scratch/ccache',
            'CCACHE_MAXSIZE=50G',
            // Buildroot's target-build ccache: same dir as the host ccache.
            // Unifies the cache across kernel + buildroot + cross-pod, and
            // (importantly) overrides buildroot's default of
            // $HOME/.buildroot-ccache -- our pod runs as a NIS uid with no
            // /etc/passwd entry, so $HOME is empty and host-ccache's install
            // step tried `mkdir -p //.buildroot-ccache` and died with
            // "Permission denied" (build #47).
            'BR2_CCACHE_DIR=/scratch/ccache',
            // Many host packages (libtool, autotools generators, perl,
            // python wheels, etc.) consult $HOME at build time. With our
            // NIS uid unmapped in the container, login resolution returns
            // empty HOME and tools try to write to /. Pin it to the pod-
            // local agent dir which is owned by jnlp (1000:30) with g+w
            // and reachable by nova-ci (150707:30) via the shared gid.
            'HOME=/home/jenkins/agent',
            'BUILDROOT_SRC=/opt/buildroot',
            // Active build output: pod-local emptyDir (NOT /scratch). Two
            // reasons: (1) the Blossom NFS server clock runs ~10-15s ahead
            // of the pod clock, so any file make creates on /scratch lands
            // with a future mtime relative to the pod; cmake's try_compile()
            // during host-cmake bootstrap produced bogus "unique_ptr - no"
            // verdicts because the sub-make couldn't trust mtime ordering
            // (build #45). (2) ~all build I/O is hot rewrites of .o/.a/.ko/
            // staging files -- pod-local SSD beats NFS round-trips by an
            // order of magnitude. ccache still accelerates compilation
            // because the compiler invocation is what's wrapped, regardless
            // of where the output lands.
            'BUILDROOT_OUT=/home/jenkins/agent/buildroot-out',
            // Buildroot defaults DL_DIR to $(TOPDIR)/dl, i.e. /opt/buildroot/dl.
            // /opt/buildroot is baked read-only into the image (a+rX, no a+w)
            // so cross-build downloads are forced onto writable NFS scratch.
            // Like ccache, this is a content cache (tarballs verified by sha)
            // so mtime semantics don't matter and cross-pod sharing is gold.
            'BR2_DL_DIR=/scratch/buildroot-dl',
          ]) {
            sh '''
              set -eux
              mkdir -p "${CCACHE_DIR}" "${BUILDROOT_OUT}" "${BR2_DL_DIR}" "${BUILDROOT_OUT}/modules"
              export KBUILD_BUILD_TIMESTAMP=''
              if [ ! -f "${BUILDROOT_OUT}/.config" ]; then
                cp "${BUILDROOT_SRC}/.config" "${BUILDROOT_OUT}/.config"
                # The image's defconfig sets
                #   BR2_ROOTFS_OVERLAY="modules overlay"
                # which buildroot resolves *relative to its topdir*
                # /opt/buildroot. Both subdirs are placeholders that the
                # CI is meant to populate -- neither exists in
                # espeer/buildroot:nova-test (the fork the image clones)
                # and /opt/buildroot is baked read-only into the image
                # anyway. Build #52 confirmed both paths break rsync:
                # the "modules" path with no source dir tripped #49/#50,
                # and after sending modules elsewhere, the still-missing
                # "overlay" path then tripped #52 with the same error.
                # Rewrite the overlay list down to a single absolute
                # entry pointing at a writable pod-local dir where we
                # deposit kernel modules via modules_install below.
                sed -i 's|^BR2_ROOTFS_OVERLAY=.*|BR2_ROOTFS_OVERLAY="'"${BUILDROOT_OUT}"'/modules"|' "${BUILDROOT_OUT}/.config"
                make -C "${BUILDROOT_SRC}" O="${BUILDROOT_OUT}" olddefconfig
              fi
              JN="$(nproc 2>/dev/null || echo 32)"
              # Buildroot's host-tools build (notably the host-cmake stage)
              # spawns big cc1plus translation units; at -j$(nproc)=128 peak
              # RSS easily exceeds the container memory limit and the OOM
              # killer takes out cc1plus mid-compile (build #46). Cap the
              # buildroot job-count to something the memory budget can
              # actually feed in parallel; the kernel build above stays at
              # full ${JN} since clang TUs are much smaller.
              BR_JN="$(( JN > 32 ? 32 : JN ))"
              time make LLVM=1 CC="ccache clang" -j"${JN}"
              # Note the /usr suffix: kernel modules_install always writes
              # <INSTALL_MOD_PATH>/lib/modules/<ver>, but the buildroot
              # target uses a merged-/usr layout and rejects an overlay
              # that has a top-level /lib (build #51 died with
              #   ERROR: The overlay in .../modules is not using a merged
              #   /usr for the following directories: /lib
              # ). Setting INSTALL_MOD_PATH to <overlay>/usr puts modules
              # at <overlay>/usr/lib/modules/<ver>/, which is what the
              # merged-/usr sanity check wants.
              time make modules_install INSTALL_MOD_PATH="${BUILDROOT_OUT}/modules/usr"
              time make -C "${BUILDROOT_SRC}" O="${BUILDROOT_OUT}" -j"${BR_JN}"
            '''
          }
        }
      }

      // Run once per pipeline -- `colossus login` writes its token under $HOME on the
      // nova-ci container. HOME is pinned to /home/jenkins/agent (see Build stage) which
      // is shared across every container('nova-ci') block on this pod, so subsequent
      // Provision / finally calls inherit the auth state without re-logging in.
      // We pass --client-id / --client-secret via env to keep them off `set -x` traces
      // and out of process argv (visible in /proc).
      stageName = 'Colossus login'
      stage(stageName) {
        container('nova-ci') {
          withCredentials([usernamePassword(
            credentialsId: 'github-token',
            passwordVariable: 'GIT_PASSWORD',
            usernameVariable: 'GIT_USERNAME'
          )]) {
            GithubHelper.getInstance("${GIT_PASSWORD}", githubData).updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
          }
          withCredentials([usernamePassword(
            credentialsId: 'colossus-ssa',
            usernameVariable: 'COLOSSUS_CLIENT_ID',
            passwordVariable: 'COLOSSUS_CLIENT_SECRET'
          )]) {
            // Same HOME pin as Build (and reused by Provision + finally): our NIS uid
            // 150707 has no /etc/passwd entry so the container's default HOME is "",
            // which would send `colossus login`'s token cache to "/" and fail.
            withEnv(['HOME=/home/jenkins/agent']) {
              sh '''
                set -eu
                # Jenkins "Username with password" credential fields preserve trailing
                # whitespace from paste, which Starfleet's /token endpoint rejects byte-
                # for-byte ("None of requested scopes granted to client in service" with
                # a single trailing 0x0a sneaks through). Strip CR/LF defensively so a
                # future credential rotation can't silently break the pipeline.
                CSEC="$(printf '%s' "${COLOSSUS_CLIENT_SECRET}" | tr -d '\r\n')"
                colossus login --method ssa \
                  --client-id "${COLOSSUS_CLIENT_ID}" \
                  --client-secret "${CSEC}"
                colossus bm region list >/dev/null
                echo "Colossus SSA login OK (token cached under ${HOME})"
              '''
            }
          }
        }
      }

      stageName = 'Provision'
      stage(stageName) {
        container('nova-ci') {
          withCredentials([usernamePassword(
            credentialsId: 'github-token',
            passwordVariable: 'GIT_PASSWORD',
            usernameVariable: 'GIT_USERNAME'
          )]) {
            GithubHelper.getInstance("${GIT_PASSWORD}", githubData).updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
          }
          withEnv([
            "ANSIBLE_GIT_URL=${params.ANSIBLE_GIT_URL}",
            "ANSIBLE_GIT_BRANCH=${params.ANSIBLE_GIT_BRANCH}",
            "ANSIBLE_PLAYBOOK=${params.ANSIBLE_PLAYBOOK}",
            // colossus reads its cached SSA token from $HOME (set in Colossus login).
            'HOME=/home/jenkins/agent',
          ]) {
            // Shebang on line 1 makes Jenkins's durable-task run this with
            // bash rather than /bin/sh -> dash on Ubuntu 24.04, which the
            // <(...) process-substitutions below rely on (build #53 hit
            //   script.sh.copy: 8: Syntax error: "(" unexpected
            // ).
            sh '''#!/bin/bash
              set -euxo pipefail

              # colossus bm lease list -j returns exit code 1 when the lease
              # set is empty (like grep -- "no results" treated as failure)
              # but writes a valid empty JSON array "[]" to stdout. Under
              # set -eo pipefail this would kill the script the moment we
              # have zero leases, which is exactly the case on a freshly-
              # onboarded SSA client. Distinguish "empty result" from "real
              # error" by validating that stdout parses as a JSON array;
              # any other output (auth banner, http error, etc) still fails
              # loudly with the raw output dumped for diagnosis.
              get_leases() {
                local raw
                raw=$(colossus bm lease list -j 2>&1) || true
                if ! printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
                  echo 'colossus bm lease list -j produced non-JSON output:' >&2
                  printf '%s\\n' "$raw" >&2
                  return 1
                fi
                printf '%s' "$raw" | jq -r '.[] | select(.entity_details.leaseJustification // "" | contains("Nova CI/CD")) | "\\(.entity_details.id),\\(.entity_details.status),\\(.entity_details.ipAddress),\\(.entity_details.leaseJustification)"' | tee leases.txt
              }
              get_leases
              grep -v -f <(cut -d, -f5 leases.txt) target-gpu-arch.txt | xargs -I{} colossus bm lease create -d 7d \\
                -agb "${ANSIBLE_GIT_BRANCH}" -agu "${ANSIBLE_GIT_URL}" -apb "${ANSIBLE_PLAYBOOK}" \\
                -lj "Nova CI/CD,{}" -o ubuntu-25.10-x86_64-standard-uefi \\
                -f "gpus.architecture={}" "cpus.sockets.arch=x86_64"
              while grep -v -f <(cut -d, -f5 leases.txt) target-gpu-arch.txt || grep -v RESERVED leases.txt >/dev/null; do
                sleep 30
                get_leases
              done
            '''
          }
        }
      }

      stageName = 'Deploy'
      stage(stageName) {
        container('nova-ci') {
          withCredentials([usernamePassword(
            credentialsId: 'github-token',
            passwordVariable: 'GIT_PASSWORD',
            usernameVariable: 'GIT_USERNAME'
          )]) {
            GithubHelper.getInstance("${GIT_PASSWORD}", githubData).updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
          }
          withEnv([
            // Same pod-local emptyDir as the Build stage (the rootfs.cpio
            // is produced there; /scratch isn't where it lands). With
            // O=${BUILDROOT_OUT} set explicitly, images/ is a direct
            // child of BUILDROOT_OUT -- no "output/" prefix.
            'BUILDROOT_OUT=/home/jenkins/agent/buildroot-out',
            // ssh/scp call getpwuid(getuid()) at startup and fatal-exit if
            // the lookup fails -- our NIS uid 150707 has no /etc/passwd
            // entry in the container (build #57: "scp: unknown user 150707").
            // /etc/passwd isn't writable as non-root, so we provide a fake
            // passwd DB via the libnss_wrapper LD_PRELOAD library written
            // out below. HOME pin is also required because that's what
            // ssh advertises as pw_dir.
            'HOME=/home/jenkins/agent',
            'LD_PRELOAD=libnss_wrapper.so',
            'NSS_WRAPPER_PASSWD=/home/jenkins/agent/nss-passwd',
            'NSS_WRAPPER_GROUP=/home/jenkins/agent/nss-group',
          ]) {
          sh '''
            set -eux
            printf 'ciuser:x:%s:%s::%s:/bin/bash\n' "$(id -u)" "$(id -g)" "${HOME}" > "${NSS_WRAPPER_PASSWD}"
            printf 'cigroup:x:%s:\n' "$(id -g)" > "${NSS_WRAPPER_GROUP}"
            SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=300 -o ServerAliveInterval=2 -o ServerAliveCountMax=1"
            BZIMAGE="${WORKSPACE}/arch/x86_64/boot/bzImage"
            INITRD="${BUILDROOT_OUT}/images/rootfs.cpio"
            while IFS= read -r TARGET; do
              IP=$(echo "${TARGET}" | cut -d, -f3)
              scp ${SSH_OPTS} "${BZIMAGE}" "root@${IP}:/"
              scp ${SSH_OPTS} "${INITRD}" "root@${IP}:/"
              echo "Loading kexec kernel on ${IP}..."
              ssh -n ${SSH_OPTS} "root@${IP}" 'kexec -l /bzImage --initrd=/rootfs.cpio --append="ignore_loglevel console=ttyS1,115200n8"'
              echo "Booting kernel..."
              ssh -n ${SSH_OPTS} "root@${IP}" "kexec -e" || true
            done < leases.txt
            echo "Waiting for boot to complete..."
            sleep 30
          '''
          }
        }
      }

      stageName = 'Test'
      stage(stageName) {
        container('nova-ci') {
          withCredentials([usernamePassword(
            credentialsId: 'github-token',
            passwordVariable: 'GIT_PASSWORD',
            usernameVariable: 'GIT_USERNAME'
          )]) {
            GithubHelper.getInstance("${GIT_PASSWORD}", githubData).updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
          }
          withEnv([
            // ssh needs getpwuid() to resolve our NIS uid; see comment in
            // Deploy stage. /home/jenkins/agent persists across containers
            // in the same pod, so the nss-passwd file written by Deploy is
            // still here -- but write it again defensively in case Deploy
            // was skipped or the pod recycled between stages.
            'HOME=/home/jenkins/agent',
            'LD_PRELOAD=libnss_wrapper.so',
            'NSS_WRAPPER_PASSWD=/home/jenkins/agent/nss-passwd',
            'NSS_WRAPPER_GROUP=/home/jenkins/agent/nss-group',
          ]) {
            sh '''
              set -eux
              if [ ! -f "${NSS_WRAPPER_PASSWD}" ]; then
                printf 'ciuser:x:%s:%s::%s:/bin/bash\n' "$(id -u)" "$(id -g)" "${HOME}" > "${NSS_WRAPPER_PASSWD}"
                printf 'cigroup:x:%s:\n' "$(id -g)" > "${NSS_WRAPPER_GROUP}"
              fi
              SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
              while IFS= read -r TARGET; do
                IP=$(echo "${TARGET}" | cut -d, -f3)
                GPU_ARCH=$(echo "${TARGET}" | cut -d, -f5)
                ssh -n ${SSH_OPTS} "root@${IP}" "journalctl && avocado run /root/driver-load-test.sh --tap -" | tee -a "${GPU_ARCH}.tap"
              done < leases.txt
            '''
          }
        }
      }

      stageName = 'Summarize'
      stage(stageName) {
        container('nova-ci') {
          sh '''
            set -eux
            if ! ls *.tap >/dev/null 2>&1; then
              echo "No TAP files found"
              exit 1
            fi
            SUMMARY_AWK=/usr/local/share/nova-ci/tap-summary.gawk
            test -r "${SUMMARY_AWK}"
            command -v gawk >/dev/null 2>&1 || { echo "gawk (GNU awk) required in CI_IMAGE; see ci/Dockerfile" >&2; exit 1; }
            gawk --file "${SUMMARY_AWK}" --sandbox -- *.tap > "${WORKSPACE}/tap-summary.md"
            echo "---- TAP summary (Markdown) ----"
            cat "${WORKSPACE}/tap-summary.md"
            echo "---- raw TAP files ----"
            for f in *.tap; do echo "==== ${f} ===="; cat "${f}"; done
          '''
        }
      }

      stageName = 'Post TAP comment'
      stage(stageName) {
        container('nova-ci') {
          try {
            withCredentials([usernamePassword(
              credentialsId: 'github-token',
              passwordVariable: 'GIT_PASSWORD',
              usernameVariable: 'GIT_USERNAME'
            )]) {
              withEnv([
                "GH_REPO=${repoName}",
                "GH_ISSUE=${prNum}",
              ]) {
                sh '''
                  set -eu
                  if ! test -f "${WORKSPACE}/tap-summary.md"; then
                    echo "No tap-summary.md; skipping PR comment"
                    exit 0
                  fi
                  if ! command -v jq >/dev/null 2>&1; then
                    echo "jq not found; skipping PR comment" >&2
                    exit 1
                  fi
                  PREFIX=$(printf '%s\n\n' "[nova-ci] TAP summary — build ${BUILD_NUMBER} — ${BUILD_URL}")
                  jq -n --arg prefix "${PREFIX}" --rawfile t "${WORKSPACE}/tap-summary.md" \
                    '{body: ($prefix + $t)}' > "${WORKSPACE}/pr-comment.json"
                  curl -fsS -X POST \
                    -H "Accept: application/vnd.github+json" \
                    -H "Authorization: token ${GIT_PASSWORD}" \
                    -H "X-GitHub-Api-Version: 2022-11-28" \
                    --data-binary "@${WORKSPACE}/pr-comment.json" \
                    "https://api.github.com/repos/${GH_REPO}/issues/${GH_ISSUE}/comments"
                '''
              }
            }
          } catch (Exception tapCommentEx) {
            echo "Could not post TAP summary PR comment (build continues): ${tapCommentEx}"
          }
        }
      }

      stageName = 'Status'
      stage(stageName) {
        container('nova-ci') {
          sh '''
            set -eux
            if cat *.tap | grep "^not ok"; then
              exit 1
            fi
            echo "All tests PASSED!"
          '''
        }
      }

      // Chained-inline so the GithubHelper instance is never bound to a local
      // variable that survives the closure boundary; CPS save points cannot
      // serialize org.kohsuke.github.GHCommitStatus (returned by updateCommitStatus
      // and held in the helper's internal state), so any retained instance
      // poisons the next saveProgram. uploadLogs is omitted for the same reason:
      // it leaves a reference graph behind that breaks serialization on the next
      // step boundary (consistently broke the finally block before this change).
      // The trailing echo is load-bearing: it overwrites the closure's
      // ValueBoundContinuation.v (the in-flight return value of the last
      // expression) with the echo step's null return. Without it, the
      // GHCommitStatus returned by updateCommitStatus sits in v until the
      // next save -- entering finally's container() -- and dies there.
      withCredentials([usernamePassword(
        credentialsId: 'github-token',
        passwordVariable: 'GIT_PASSWORD',
        usernameVariable: 'GIT_USERNAME'
      )]) {
        GithubHelper.getInstance("${GIT_PASSWORD}", githubData).updateCommitStatus("${BUILD_URL}", 'Complete', GitHubCommitState.SUCCESS)
        echo "DIAG: posted Complete SUCCESS status"
      }

    } catch (Exception ex) {
      currentBuild.result = 'FAILURE'
      echo "DIAG-catch: ${ex}"
      if (tokenAcquired) {
        try {
          withCredentials([usernamePassword(
            credentialsId: 'github-token',
            passwordVariable: 'GIT_PASSWORD',
            usernameVariable: 'GIT_USERNAME'
          )]) {
            GithubHelper.getInstance("${GIT_PASSWORD}", githubData).updateCommitStatus("${BUILD_URL}", "${stageName} Failed", GitHubCommitState.FAILURE)
            echo "DIAG: posted ${stageName} Failed status"
          }
        } catch (Exception ignored) {
          echo "Could not update GitHub status: ${ignored}"
        }
      }
    } finally {
      container('nova-ci') {
        // HOME = where Colossus login cached the SSA token; without it the cleanup
        // would re-prompt for auth and fail silently (set +e).
        withEnv(['HOME=/home/jenkins/agent']) {
          sh '''
            set +e
            if [ -f leases.txt ]; then
              while IFS= read -r TARGET; do
                ID=$(echo "${TARGET}" | cut -d, -f1)
                echo "Rebooting ${ID}..."
                colossus bm reboot --resource-id "${ID}"
              done < leases.txt
              echo "Waiting..."
              sleep 180
            fi
          '''
        }
      }
    }
  }
}
