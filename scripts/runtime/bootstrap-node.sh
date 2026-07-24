#!/usr/bin/env bash
# Downloads a portable Node.js into runtime/node without needing Node.js.
#
# POSIX twin of bootstrap-node.ps1. This is the no-Node escape hatch for a fresh
# clone on a bare Linux/macOS machine: runtime/node is gitignored, so a clone has
# no bundled Node, and bootstrap-host-native.cjs cannot download one because it
# is itself a Node script. scripts/pcoder calls this when it finds no Node, then
# re-execs.
#
# Mirrors downloadAndExtractNode() in bootstrap-host-native.cjs: same dist URL,
# same SHASUMS256.txt verification, same runtime/node layout. The pinned version
# comes from node-version.txt, which all three bootstrappers read, so they
# cannot drift.
#
# Sticks to tools present on a minimal Ubuntu / Alma-RHEL install, and probes
# for alternatives (curl vs wget, sha256sum vs shasum vs openssl) rather than
# assuming any one of them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NODE_DIR="${REPO_ROOT}/runtime/node"
TMP_DIR="${REPO_ROOT}/state/tmp"
VERSION_FILE="${SCRIPT_DIR}/node-version.txt"

fail() {
  echo "Error: $*" >&2
  exit 1
}

# Single source of truth for the version: scripts/runtime/node-version.txt,
# shared with bootstrap-host-native.cjs and bootstrap-node.ps1.
read_node_version() {
  [[ -f "${VERSION_FILE}" ]] ||
    fail "Missing ${VERSION_FILE} - cannot determine the pinned Node.js version."
  local version
  # Strip CR as well as LF: the folder is meant to survive a Windows clone being
  # copied straight onto a Linux box.
  version="$(tr -d '\r\n' <"${VERSION_FILE}")"
  [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "Invalid Node.js version in ${VERSION_FILE}: '${version}'"
  printf '%s' "${version}"
}

detect_platform() {
  case "$(uname -s)" in
    Linux) printf 'linux' ;;
    Darwin) printf 'darwin' ;;
    *) fail "Unsupported platform: $(uname -s). Install Node.js manually and re-run." ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) fail "Unsupported architecture: $(uname -m). Install Node.js manually and re-run." ;;
  esac
}

download() {
  local url="$1" dest="$2" attempt
  for attempt in 1 2 3; do
    if command -v curl >/dev/null 2>&1; then
      if curl -fSL --retry 2 -o "${dest}" "${url}"; then return 0; fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -q -O "${dest}" "${url}"; then return 0; fi
    else
      fail "Neither curl nor wget is available. Install one, or install Node.js directly."
    fi
    [[ ${attempt} -lt 3 ]] && echo "  Attempt ${attempt} failed, retrying..." && sleep 2
  done
  fail "Failed to download ${url} after 3 attempts."
}

sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "${file}" | awk '{print $NF}'
  else
    fail "No SHA-256 tool found (sha256sum, shasum, or openssl). Refusing to skip verification."
  fi
}

NODE_VERSION="$(read_node_version)"
PLATFORM="$(detect_platform)"
ARCH="$(detect_arch)"

if [[ "${PLATFORM}" == "darwin" ]]; then
  EXT='tar.gz'
  TAR_FLAG='-xzf'
else
  EXT='tar.xz'
  TAR_FLAG='-xJf'
  # GNU tar shells out to the xz binary for -J; minimal RHEL images often lack it.
  if ! command -v xz >/dev/null 2>&1; then
    fail "xz is required to extract ${EXT}. Install it (dnf install -y xz / apt-get install -y xz-utils) and re-run."
  fi
fi

FILE_NAME="node-${NODE_VERSION}-${PLATFORM}-${ARCH}.${EXT}"
URL="https://nodejs.org/dist/${NODE_VERSION}/${FILE_NAME}"
SHASUMS_URL="https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt"

echo "No Node.js found. Bootstrapping a portable copy."
echo "Platform: ${PLATFORM}/${ARCH}"
echo "Node.js:  ${NODE_VERSION}"
echo ''

mkdir -p "${TMP_DIR}"
DOWNLOAD_PATH="${TMP_DIR}/${FILE_NAME}"
SHASUMS_PATH="${TMP_DIR}/node-SHASUMS256.txt"

echo "Downloading Node.js from ${URL}..."
download "${URL}" "${DOWNLOAD_PATH}"
download "${SHASUMS_URL}" "${SHASUMS_PATH}"
echo "Downloaded: ${DOWNLOAD_PATH}"

# Verify against the official checksums before extracting anything.
EXPECTED="$(awk -v want="${FILE_NAME}" '$2 == want { print $1; exit }' "${SHASUMS_PATH}")"
[[ -n "${EXPECTED}" ]] ||
  fail "${FILE_NAME} not listed in SHASUMS256.txt - refusing to extract."

ACTUAL="$(sha256_of "${DOWNLOAD_PATH}")"
if [[ "${EXPECTED}" != "${ACTUAL}" ]]; then
  rm -f "${DOWNLOAD_PATH}"
  fail "SHA-256 mismatch for ${FILE_NAME}: expected ${EXPECTED}, got ${ACTUAL}."
fi
echo "Checksum verified: ${ACTUAL}"

echo 'Extracting...'
EXTRACT_DIR="${TMP_DIR}/node-extract"
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar "${TAR_FLAG}" "${DOWNLOAD_PATH}" -C "${EXTRACT_DIR}"

INNER="$(find "${EXTRACT_DIR}" -maxdepth 1 -mindepth 1 -type d -name 'node-*' | head -n 1)"
[[ -n "${INNER}" ]] || fail "Could not find extracted Node.js directory in ${EXTRACT_DIR}"

rm -rf "${NODE_DIR}"
mkdir -p "$(dirname "${NODE_DIR}")"
mv "${INNER}" "${NODE_DIR}"

rm -rf "${EXTRACT_DIR}"
rm -f "${DOWNLOAD_PATH}"

NODE_EXE="${NODE_DIR}/bin/node"
[[ -x "${NODE_EXE}" ]] || fail "Bootstrap finished but ${NODE_EXE} is missing or not executable."

echo "Node.js extracted to ${NODE_DIR}"
echo "Bundled Node.js version: $("${NODE_EXE}" --version)"
