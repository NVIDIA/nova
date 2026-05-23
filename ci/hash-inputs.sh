#!/usr/bin/env bash
# Compute the content-addressed tag suffix for the nova-ci image.
#
# Output: a 12-character lowercase hex string written to stdout, with
# no trailing whitespace. The final image tag is "image-<output>".
#
# The hash inputs are everything listed in ci/image-manifest. Two of
# those lines start with `input=`; for each, this script:
#   - if a file: emits "<relpath><TAB>sha256(content)"
#   - if a directory: emits one such line per file in the subtree,
#     sorted by relpath.
# Pins (the non-`input=` lines) are covered automatically because the
# manifest itself is listed as an input.
#
# The list of "path<TAB>sha256" lines is sorted (LC_ALL=C, lexicographic
# byte order, stable across glibc/BSD locales) and passed through
# sha256sum; the first 12 chars of the resulting hex are the tag suffix.
#
# Reproducibility notes:
#   - sha256sum is in GNU coreutils on Linux. macOS's built-in is
#     `shasum -a 256`, which produces the same digest but a slightly
#     different output format; this script tries sha256sum first and
#     falls back to shasum.
#   - LC_ALL=C is set so sort uses byte-order, not locale collation
#     (Turkish locales fold I/i differently, etc.).
#   - Symlinks are hashed by their link target string, not by the file
#     they point at -- the Dockerfile COPY and buildroot's rsync into
#     the rootfs both preserve link targets verbatim, so the target
#     string is what ends up in the final image.
#   - We assume file paths under ci/ do not contain newlines or shell
#     metacharacters. They are repo-controlled, so this is fine.
#
# Usage:
#   ci/hash-inputs.sh                  # prints e.g. "a1b2c3d4e5f6"
#   ci/hash-inputs.sh --verbose        # also prints the per-file lines
#                                        to stderr for debugging diffs

set -euo pipefail
export LC_ALL=C

verbose=0
if [[ "${1:-}" == "--verbose" ]]; then
  verbose=1
fi

CI_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${CI_DIR}/image-manifest"
if [[ ! -f "${MANIFEST}" ]]; then
  echo "ERROR: ${MANIFEST} not found" >&2
  exit 1
fi

# Locate a sha256 utility. Prefer sha256sum (Linux + brew coreutils);
# fall back to `shasum -a 256` (macOS default).
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 | cut -d' ' -f1; }
else
  echo "ERROR: need sha256sum or shasum on PATH" >&2
  exit 1
fi

# Read input= lines from the manifest. Trim trailing CR (Windows line
# endings) just in case someone edits this file on a non-Unix box and
# git's autocrlf chooses violence.
inputs=()
while IFS= read -r line; do
  line="${line%$'\r'}"
  case "${line}" in
    ''|'#'*) continue ;;
    input=*) inputs+=("${line#input=}") ;;
    *) : ;;  # pin line; covered by the manifest's self-inclusion
  esac
done < "${MANIFEST}"

if [[ "${#inputs[@]}" -eq 0 ]]; then
  echo "ERROR: no input= lines in ${MANIFEST}" >&2
  exit 1
fi

# Build the list of relpaths to hash. For files, just append. For
# directories, walk recursively with find (-type f -or -type l so we
# include symlinks too). Paths are kept relative to CI_DIR so the hash
# doesn't depend on absolute location.
relpaths=()
for inp in "${inputs[@]}"; do
  abs="${CI_DIR}/${inp}"
  if [[ -f "${abs}" || -L "${abs}" ]]; then
    relpaths+=("${inp}")
  elif [[ -d "${abs}" ]]; then
    # find inside ci/, then strip the leading "ci/" so the printed
    # relpath is relative to the manifest dir.
    while IFS= read -r line; do
      relpaths+=("${line}")
    done < <(cd "${CI_DIR}" && find "${inp}" \( -type f -o -type l \) | sort)
  else
    echo "ERROR: manifest input '${inp}' is neither a file, symlink, nor directory under ${CI_DIR}" >&2
    exit 1
  fi
done

# Sort the full relpath list (and dedup, in case the manifest listed a
# dir and a file inside it).
sorted_relpaths=()
while IFS= read -r line; do
  sorted_relpaths+=("${line}")
done < <(printf '%s\n' "${relpaths[@]}" | sort -u)

# Compute "<relpath><TAB><sha256>" for each, in sorted order, and pipe
# the whole thing through sha256 again. The first 12 hex chars are the
# tag suffix.
tmp="$(mktemp -t nova-ci-hash.XXXXXX)"
trap 'rm -f "${tmp}"' EXIT
for rel in "${sorted_relpaths[@]}"; do
  abs="${CI_DIR}/${rel}"
  if [[ -L "${abs}" ]]; then
    target="$(readlink "${abs}")"
    digest="$(printf 'symlink:%s' "${target}" | sha256)"
  else
    digest="$(sha256 < "${abs}")"
  fi
  printf '%s\t%s\n' "${rel}" "${digest}" >> "${tmp}"
done

if [[ "${verbose}" -eq 1 ]]; then
  cat "${tmp}" >&2
fi

sha256 < "${tmp}" | cut -c1-12
