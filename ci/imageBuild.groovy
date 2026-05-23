// imageBuild.groovy -- helpers for the nova-ci agent image lifecycle.
//
// `load` this from the main Jenkinsfile (it lives in the repo so it's
// versioned alongside the pipeline that consumes it):
//
//     def imageBuild = load 'ci/imageBuild.groovy'
//     def ciImage = imageBuild.ensureImage(
//         gitlabCredId: 'gitlab_epeer',
//         artifactoryCredId: 'artifactory-token')
//
// The returned string is the full image ref (registry/repo:image-<sha12>)
// to plug into the main pod's nova-ci containerTemplate.
//
// Execution model: the caller must be inside a podTemplate that has at
// least `jnlp` (for the script + curl invocations) AND `kaniko` (for
// the build, only invoked on a cache miss). The pod does NOT need
// nova-ci -- this script runs *before* the heavy CI pod is allocated.
//
// Stages exposed to the pipeline UI:
//   - "Ensure agent image" (always runs; the inner kaniko block is
//     skipped on a registry hit, so the green checkmark on a hit
//     completes in seconds).

def ensureImage(Map opts) {
  String registry          = opts.registry          ?: 'gitlab-master.nvidia.com:5005'
  String repo              = opts.repo              ?: 'epeer/nova-test/nova-kernel-ci'
  String gitlabCredId      = opts.gitlabCredId      ?: 'gitlab_epeer'
  String artifactoryCredId = opts.artifactoryCredId ?: 'artifactory-token'

  // Compute the content-addressed tag from ci/image-manifest + listed
  // inputs. hash-inputs.sh is the single source of truth -- this
  // groovy never re-implements the hash; it just shells out and trusts
  // the script (which is itself part of the repo, version-controlled,
  // and trivially unit-testable from a developer laptop).
  String hash = sh(returnStdout: true, script: 'ci/hash-inputs.sh').trim()
  if (!(hash ==~ /[0-9a-f]{12}/)) {
    error("imageBuild: hash-inputs.sh produced invalid output: '${hash}'")
  }
  String tag = "image-${hash}"
  String imageFull = "${registry}/${repo}:${tag}"
  echo "imageBuild: computed tag = ${tag}"
  echo "imageBuild: target image = ${imageFull}"

  // Read manifest pins. These become --build-arg values for kaniko on
  // the rebuild path; on the cache-hit path we don't need them but
  // logging them is cheap and helps debug "why did this rebuild?"
  // (the answer is always a hash change, and a pin change is the
  // most common cause of that).
  Map pins = parseManifestPins()
  echo "imageBuild: manifest pins = ${pins}"
  ['buildroot_tag', 'linux_firmware_sha', 'colossus_version'].each { k ->
    if (!pins[k]) error("imageBuild: ci/image-manifest is missing required pin '${k}'")
  }

  // Probe the registry. We split this off into its own block (and
  // wrap it in withCredentials) so the bearer-token exchange has the
  // GitLab basic-auth available; on a cache hit we exit here.
  boolean exists = false
  withCredentials([usernamePassword(
      credentialsId: gitlabCredId,
      usernameVariable: 'GITLAB_USER',
      passwordVariable: 'GITLAB_TOKEN')]) {
    exists = _imageExists(registry, repo, tag)
  }
  if (exists) {
    echo "imageBuild: ${imageFull} already in registry; skipping rebuild"
    return imageFull
  }
  echo "imageBuild: ${imageFull} not in registry; building with kaniko"

  // Stage the build context on jnlp (curl, bash, tar -- kaniko's
  // distroless busybox layer is too minimal to host the colossus
  // download). build-image.sh writes Dockerfile + buildroot.config +
  // overlay/ + colossus-cli.tar.gz into the staging dir.
  String ctx = '/home/jenkins/agent/ctx'
  withCredentials([usernamePassword(
      credentialsId: artifactoryCredId,
      usernameVariable: 'ARTIFACTORY_USER',
      passwordVariable: 'ARTIFACTORY_TOKEN')]) {
    sh """
      set -eux
      rm -rf '${ctx}'
      COLOSSUS_VERSION='${pins.colossus_version}' \\
        ci/build-image.sh --stage-only '${ctx}' --tag '${tag}'
      ls -la '${ctx}'
    """
  }

  // Run kaniko. config.json is synthesized at runtime from the
  // gitlab_epeer cred (basic-auth-over-https against the GitLab
  // registry); the surrounding `set +x` block keeps the token out of
  // the build log.
  container('kaniko') {
    withCredentials([usernamePassword(
        credentialsId: gitlabCredId,
        usernameVariable: 'GITLAB_USER',
        passwordVariable: 'GITLAB_TOKEN')]) {
      sh """#!/busybox/sh
        set -eu
        mkdir -p /kaniko/.docker
        {
          set +x
          AUTH_B64=\$(printf '%s:%s' "\$GITLAB_USER" "\$GITLAB_TOKEN" | base64 | tr -d '\\n')
          printf '{"auths":{"${registry}":{"auth":"%s"}}}\\n' "\$AUTH_B64" > /kaniko/.docker/config.json
        } 2>/dev/null
        chmod 0600 /kaniko/.docker/config.json
        set -x
        /kaniko/executor \\
          --context=dir://${ctx} \\
          --dockerfile=${ctx}/Dockerfile \\
          --destination='${imageFull}' \\
          --build-arg BUILDROOT_TAG=${pins.buildroot_tag} \\
          --build-arg LINUX_FIRMWARE_GIT_SHA=${pins.linux_firmware_sha} \\
          --snapshot-mode=redo \\
          --use-new-run \\
          --cleanup \\
          --verbosity=info
      """
    }
  }

  // Cleanup the staged dir; the next pipeline run starts with a fresh
  // ${ctx} regardless, but on the same pod allocation we want it gone.
  sh "rm -rf '${ctx}' || true"

  return imageFull
}

// Parse the non-`input=` lines in ci/image-manifest into a key->value
// map. Comments and blanks are skipped. The shape mirrors the bash
// parser in hash-inputs.sh; the two must stay in sync.
Map parseManifestPins() {
  String content = readFile('ci/image-manifest')
  Map pins = [:]
  for (String raw : content.split('\n')) {
    String line = raw.trim()
    if (!line || line.startsWith('#')) continue
    if (line.startsWith('input=')) continue
    int eq = line.indexOf('=')
    if (eq <= 0) continue
    pins[line.substring(0, eq).trim()] = line.substring(eq + 1).trim()
  }
  return pins
}

// GitLab registry HEAD probe with the bearer-token dance.
//
// Returns true iff /v2/<repo>/manifests/<tag> exists. Errors out
// (rather than returning false) on anything other than 200 or 404 --
// a misconfigured probe that silently returned "not found" would
// trigger an expensive rebuild on every CI run, which we'd rather
// notice loudly than ignore quietly.
//
// Why we don't just `docker manifest inspect` or `crane manifest`:
// jnlp has neither. curl + a tiny token exchange is the lowest-
// dependency way to ask the question, and the GitLab registry's
// 401-with-WWW-Authenticate response is straightforward.
boolean _imageExists(String registry, String repo, String tag) {
  int rc = sh(returnStatus: true, script: """
    set -eu
    set +x  # don't leak GITLAB_TOKEN into the log

    URL='https://${registry}/v2/${repo}/manifests/${tag}'

    # 1. Anonymous HEAD. Capture WWW-Authenticate from the 401.
    code=\$(curl -sS -o /dev/null -w '%{http_code}' -I "\${URL}" -D /tmp/probe.headers || true)
    if [ "\${code}" = '200' ]; then
      echo 'probe: anonymous 200 (public)' >&2
      exit 0
    fi
    if [ "\${code}" != '401' ]; then
      echo "probe: unexpected status \${code} on anonymous HEAD" >&2
      exit 2
    fi

    # 2. Parse realm + service + scope from WWW-Authenticate.
    www=\$(grep -i '^www-authenticate:' /tmp/probe.headers | tr -d '\\r' || true)
    realm=\$(  printf '%s' "\${www}" | sed -nE 's/.*realm="([^"]+)".*/\\1/p')
    service=\$(printf '%s' "\${www}" | sed -nE 's/.*service="([^"]+)".*/\\1/p')
    scope=\$(  printf '%s' "\${www}" | sed -nE 's/.*scope="([^"]+)".*/\\1/p')
    if [ -z "\${realm}" ] || [ -z "\${service}" ]; then
      echo "probe: cannot parse WWW-Authenticate: \${www}" >&2
      exit 2
    fi
    [ -n "\${scope}" ] || scope='repository:${repo}:pull'

    # 3. Exchange basic auth -> JWT.
    token=\$(curl -sSf -u "\${GITLAB_USER}:\${GITLAB_TOKEN}" \\
      --get \\
      --data-urlencode "service=\${service}" \\
      --data-urlencode "scope=\${scope}" \\
      "\${realm}" \\
      | sed -nE 's/.*"token":"([^"]+)".*/\\1/p')
    if [ -z "\${token}" ]; then
      echo 'probe: failed to obtain registry bearer token' >&2
      exit 2
    fi

    # 4. Authed HEAD.
    auth_code=\$(curl -sS -o /dev/null -w '%{http_code}' -I \\
      -H "Authorization: Bearer \${token}" "\${URL}")
    echo "probe: authed HEAD -> \${auth_code}" >&2
    case "\${auth_code}" in
      200) exit 0 ;;
      404) exit 1 ;;
      *)
        echo "probe: unexpected status \${auth_code} on authed HEAD" >&2
        exit 2
        ;;
    esac
  """)

  switch (rc) {
    case 0:  return true
    case 1:  return false
    default: error("imageBuild: registry probe failed (rc=${rc}); refusing to assume image present or absent")
  }
}

// `load 'ci/imageBuild.groovy'` returns the script object; the caller
// then calls .ensureImage() on it.
return this
