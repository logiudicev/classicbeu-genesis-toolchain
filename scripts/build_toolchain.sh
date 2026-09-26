#!/usr/bin/env bash
# build_toolchain.sh -- builds the ClassicBEU Genesis toolchain bundle.
#
# Usage:
#   scripts/build_toolchain.sh fetch [--record]
#
# Steps are added one at a time; each can be run on its own. All scratch
# output goes to work/ (git-ignored). Versions and URLs live in versions.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT
readonly VERSIONS_FILE="${REPO_ROOT}/versions.env"
readonly CHECKSUMS_FILE="${REPO_ROOT}/checksums.sha256"
readonly WORK_DIR="${REPO_ROOT}/work"
readonly DOWNLOAD_DIR="${WORK_DIR}/downloads"

log() { printf '[toolchain] %s\n' "$*"; }
die() { printf '[toolchain] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "${VERSIONS_FILE}" ]] || die "missing ${VERSIONS_FILE}"
# shellcheck source=../versions.env
source "${VERSIONS_FILE}"

# ── Host detection ──────────────────────────────────────────────────────────
# Linux and macOS spell things differently; everything OS-specific is
# decided here, once, so the steps below never branch on the OS themselves.
detect_host() {
    case "$(uname -s)" in
        Linux)  HOST_OS="linux" ;;
        Darwin) HOST_OS="macos" ;;
        *)      die "unsupported host OS: $(uname -s)" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  HOST_ARCH="x64" ;;
        arm64|aarch64) HOST_ARCH="arm64" ;;
        *)             die "unsupported CPU: $(uname -m)" ;;
    esac
    # Linux ships sha256sum; macOS ships shasum. Same checksum file format.
    if   command -v sha256sum >/dev/null 2>&1; then SHA256=(sha256sum)
    elif command -v shasum    >/dev/null 2>&1; then SHA256=(shasum -a 256)
    else die "need sha256sum or shasum"; fi
    command -v curl >/dev/null 2>&1 || die "curl not found"
}

# ── fetch ───────────────────────────────────────────────────────────────────
# Downloads to "<file>.part" and renames only on success, so an interrupted
# download never looks finished. Files already present are not re-downloaded.
download() {
    local file="$1" url="$2"
    local dest="${DOWNLOAD_DIR}/${file}"
    if [[ -f "${dest}" ]]; then log "already have ${file}"; return 0; fi
    log "downloading ${file}"
    curl --fail --location --retry 3 --progress-bar --output "${dest}.part" "${url}"
    mv "${dest}.part" "${dest}"
}

step_fetch() {
    local record=0 arg
    for arg in "$@"; do
        case "${arg}" in
            --record) record=1 ;;
            *)        die "unknown option for fetch: ${arg}" ;;
        esac
    done

    mkdir -p "${DOWNLOAD_DIR}"
    local files=() entry
    for entry in "${ARTIFACTS[@]}"; do
        download "${entry%%|*}" "${entry#*|}"
        files+=("${entry%%|*}")
    done

    if (( record )); then
        # Refuse to silently re-pin: changing pinned sources must be deliberate.
        [[ ! -e "${CHECKSUMS_FILE}" ]] || die "checksums.sha256 already exists; delete it on purpose to re-pin"
        ( cd "${DOWNLOAD_DIR}" && "${SHA256[@]}" "${files[@]}" ) > "${CHECKSUMS_FILE}"
        log "recorded checksums.sha256 -- review it, then commit it"
        return 0
    fi

    [[ -f "${CHECKSUMS_FILE}" ]] || die "no checksums.sha256 yet; run 'fetch --record' once"
    local f
    for f in "${files[@]}"; do
        grep -qF "  ${f}" "${CHECKSUMS_FILE}" || die "${f} has no pinned checksum"
    done
    ( cd "${DOWNLOAD_DIR}" && "${SHA256[@]}" -c "${CHECKSUMS_FILE}" ) \
        || die "checksum mismatch -- delete the FAILED file from work/downloads and re-run"
    log "all sources verified on ${HOST_OS}-${HOST_ARCH}"
}

# ── Entry point ─────────────────────────────────────────────────────────────
main() {
    detect_host
    local step="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "${step}" in
        fetch) step_fetch "$@" ;;
        *)     die "usage: scripts/build_toolchain.sh fetch [--record]" ;;
    esac
}

main "$@"