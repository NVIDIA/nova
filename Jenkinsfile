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
// - Colossus: configure auth the same way as on self-hosted runners (env or credentials).
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
    string(name: 'CI_IMAGE', defaultValue: 'gitlab-master.nvidia.com:5005/epeer/nova-test/nova-kernel-ci:2026-05-13', description: 'Image with kernel build toolchain + colossus CLI + ssh'),
    string(name: 'ANSIBLE_GIT_URL', defaultValue: 'https://gitlab-master.nvidia.com/epeer/nova-test.git', description: 'Git URL passed to colossus bm lease -agu (Ansible playbooks)'),
    string(name: 'ANSIBLE_GIT_BRANCH', defaultValue: 'main', description: 'Branch for -agb (playbook / lease metadata; epeer/nova-test on GitLab)'),
    string(name: 'ANSIBLE_PLAYBOOK', defaultValue: 'target.yml', description: 'Playbook path in repo for -apb'),
  ])
])

def defaultCiImage = 'gitlab-master.nvidia.com:5005/epeer/nova-test/nova-kernel-ci:2026-05-13'
def ciImage = (params.CI_IMAGE?.trim()) ? params.CI_IMAGE.trim() : defaultCiImage

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
            'CCACHE_DIR=/scratch/ccache',
            'CCACHE_MAXSIZE=50G',
            'BUILDROOT_SRC=/opt/buildroot',
            'BUILDROOT_OUT=/scratch/buildroot-out',
          ]) {
            sh '''
              set -eux
              mkdir -p "${CCACHE_DIR}" "${BUILDROOT_OUT}"
              export KBUILD_BUILD_TIMESTAMP=''
              if [ ! -f "${BUILDROOT_OUT}/.config" ]; then
                cp "${BUILDROOT_SRC}/.config" "${BUILDROOT_OUT}/.config"
                make -C "${BUILDROOT_SRC}" O="${BUILDROOT_OUT}" olddefconfig
              fi
              JN="$(nproc 2>/dev/null || echo 32)"
              time make LLVM=1 CC="ccache clang" -j"${JN}"
              time make modules_install INSTALL_MOD_PATH="${BUILDROOT_OUT}/output/target/usr"
              time make -C "${BUILDROOT_SRC}" O="${BUILDROOT_OUT}" -j"${JN}"
            '''
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
          ]) {
            sh '''
              set -eux
              get_leases() {
                echo "Checking leases..."
                colossus bm lease list -j | jq -r '.[] | select(.entity_details.leaseJustification // "" | contains("Nova CI/CD")) | "\\(.entity_details.id),\\(.entity_details.status),\\(.entity_details.ipAddress),\\(.entity_details.leaseJustification)"' | tee leases.txt
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
            'BUILDROOT_OUT=/scratch/buildroot-out',
          ]) {
          sh '''
            set -eux
            SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=300 -o ServerAliveInterval=2 -o ServerAliveCountMax=1"
            BZIMAGE="${WORKSPACE}/arch/x86_64/boot/bzImage"
            INITRD="${BUILDROOT_OUT}/output/images/rootfs.cpio"
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
          sh '''
            set -eux
            SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
            while IFS= read -r TARGET; do
              IP=$(echo "${TARGET}" | cut -d, -f3)
              GPU_ARCH=$(echo "${TARGET}" | cut -d, -f5)
              ssh -n ${SSH_OPTS} "root@${IP}" "journalctl && avocado run /root/driver-load-test.sh --tap -" | tee -a "${GPU_ARCH}.tap"
            done < leases.txt
          '''
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

      withCredentials([usernamePassword(
        credentialsId: 'github-token',
        passwordVariable: 'GIT_PASSWORD',
        usernameVariable: 'GIT_USERNAME'
      )]) {
        def h = GithubHelper.getInstance("${GIT_PASSWORD}", githubData)
        h.uploadLogs(this, env.JOB_NAME, env.BUILD_NUMBER, null, null)
        h.updateCommitStatus("${BUILD_URL}", 'Complete', GitHubCommitState.SUCCESS)
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
            def h = GithubHelper.getInstance("${GIT_PASSWORD}", githubData)
            h.uploadLogs(this, env.JOB_NAME, env.BUILD_NUMBER, null, null)
            h.updateCommitStatus("${BUILD_URL}", "${stageName} Failed", GitHubCommitState.FAILURE)
          }
        } catch (Exception ignored) {
          echo "Could not update GitHub status or upload logs: ${ignored}"
        }
      }
    } finally {
      container('nova-ci') {
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
