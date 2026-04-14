// Nova CI on Blossom — GitHub PR webhook + Colossus hardware tests.
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

@Library('blossom-github-lib@master')
import ipp.blossom.*

properties([
  parameters([
    string(name: 'RUN_AS_UID', defaultValue: '150707', description: 'NIS uid for pod + NFS /scratch (Blossom scratch how-to); override if not epeer'),
    string(name: 'RUN_AS_GID', defaultValue: '30', description: 'Primary NIS gid for pod + NFS /scratch; override if your export differs'),
    string(name: 'CI_IMAGE', defaultValue: 'gitlab-master.nvidia.com:5005/epeer/nova-test/nova-kernel-ci:2026-04-14', description: 'Image with kernel build toolchain + colossus CLI + ssh'),
    string(name: 'ANSIBLE_GIT_URL', defaultValue: 'https://gitlab-master.nvidia.com/epeer/nova-test.git', description: 'Git URL passed to colossus bm lease -agu (Ansible playbooks)'),
    string(name: 'ANSIBLE_GIT_BRANCH', defaultValue: 'main', description: 'Branch for -agb (playbook / lease metadata; epeer/nova-test on GitLab)'),
    string(name: 'ANSIBLE_PLAYBOOK', defaultValue: 'target.yml', description: 'Playbook path in repo for -apb'),
  ])
])

def defaultCiImage = 'gitlab-master.nvidia.com:5005/epeer/nova-test/nova-kernel-ci:2026-04-14'
def ciImage = (params.CI_IMAGE?.trim()) ? params.CI_IMAGE.trim() : defaultCiImage

def runUid = params.RUN_AS_UID?.trim()
def runGid = params.RUN_AS_GID?.trim()
if (!runUid || !runGid) {
  error('Set job parameters RUN_AS_UID and RUN_AS_GID to your NIS uid/gid from `id` (see Blossom NFS scratch how-to).')
}

podTemplate(
  cloud: 'sc-ipp-blossom-prod',
  yamlMergeStrategy: org.csanchez.jenkins.plugins.kubernetes.pipeline.PodYamlMergeStrategy.merge(),
  yaml: """
apiVersion: v1
kind: Pod
spec:
  securityContext:
    runAsUser: ${runUid.toInteger()}
    runAsGroup: ${runGid.toInteger()}
  volumes:
  - name: scratch
    nfs:
      server: ipp1-cdot01-col01
      path: /vol/scratch1/scratch.epeer_blossom
  nodeSelector:
    kubernetes.io/os: "linux"
  containers:
  - name: jnlp
    volumeMounts:
    - name: scratch
      mountPath: /scratch
  - name: nova-ci
    volumeMounts:
    - name: scratch
      mountPath: /scratch
    securityContext:
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
    def githubHelper
    def stageName = ''

    stage('Get Token') {
      withCredentials([usernamePassword(
        credentialsId: 'github-token',
        passwordVariable: 'GIT_PASSWORD',
        usernameVariable: 'GIT_USERNAME'
      )]) {
        githubHelper = GithubHelper.getInstance("${GIT_PASSWORD}", githubData)
      }
    }

    try {
      currentBuild.description = githubHelper.getBuildDescription()

      stageName = 'Code checkout'
      stage(stageName) {
        githubHelper.updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
        if ('Open'.equalsIgnoreCase(githubHelper.getPRState())) {
          checkout changelog: true, poll: false, scm: [
            $class: 'GitSCM',
            branches: [[name: "pr/${githubHelper.getPRNumber()}"]],
            extensions: [],
            userRemoteConfigs: [[
              credentialsId: 'github-token',
              url: githubHelper.getCloneUrl(),
              refspec: '+refs/pull/*/head:refs/remotes/origin/pr/*'
            ]]
          ]
        } else if ('Merged'.equalsIgnoreCase(githubHelper.getPRState())) {
          checkout changelog: true, poll: false, scm: [
            $class: 'GitSCM',
            branches: [[name: githubHelper.getMergedSHA()]],
            extensions: [],
            userRemoteConfigs: [[
              credentialsId: 'github-token',
              url: githubHelper.getCloneUrl(),
              refspec: '+refs/pull/*/merge:refs/remotes/origin/pr/*'
            ]]
          ]
        }
      }

      stageName = 'Build'
      stage(stageName) {
        container('nova-ci') {
          githubHelper.updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
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
          githubHelper.updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
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
          githubHelper.updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
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
          githubHelper.updateCommitStatus("${BUILD_URL}", "${stageName} Running", GitHubCommitState.PENDING)
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
                "GH_REPO=${githubHelper.getRepoName()}",
                "GH_ISSUE=${githubHelper.getPRNumber().toString()}",
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

      githubHelper.uploadLogs(this, env.JOB_NAME, env.BUILD_NUMBER, null, null)
      githubHelper.updateCommitStatus("${BUILD_URL}", 'Complete', GitHubCommitState.SUCCESS)

    } catch (Exception ex) {
      currentBuild.result = 'FAILURE'
      echo "${ex}"
      if (githubHelper != null) {
        try {
          githubHelper.uploadLogs(this, env.JOB_NAME, env.BUILD_NUMBER, null, null)
          githubHelper.updateCommitStatus("${BUILD_URL}", "${stageName} Failed", GitHubCommitState.FAILURE)
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
