#!/usr/bin/env bash
# build_toolchain.sh -- builds the ClassicBEU Genesis toolchain bundle.
#
# Usage:
#   scripts/build_toolchain.sh fetch [--record]  download + verify the pinned sources
#   scripts/build_toolchain.sh build-gcc         build binutils + GCC for the 68000
#   scripts/build_toolchain.sh clean             delete work/ except downloads
#
# Each step can be re-run safely: finished sub-steps are remembered in
# work/stamps and skipped. All scratch output goes to work/ (git-ignored).
# Versions, URLs and target settings live in versions.env -- never here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT
readonly VERSIONS_FILE="${REPO_ROOT}/versions.env"
readonly CHECKSUMS_FILE="${REPO_ROOT}/checksums.sha256"
readonly WORK_DIR="${REPO_ROOT}/work"
readonly DOWNLOAD_DIR="${WORK_DIR}/downloads"
readonly SRC_DIR="${WORK_DIR}/src"
readonly BUILD_DIR="${WORK_DIR}/build"
readonly LOG_DIR="${WORK_DIR}/logs"
readonly STAMP_DIR="${WORK_DIR}/stamps"

log() { printf '[toolchain] %s\n' "$*"; }
die() { printf '[toolchain] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "${VERSIONS_FILE}" ]] || die "missing ${VERSIONS_FILE}"
# shellcheck source=../versions.env
source "${VERSIONS_FILE}"

# ── Host detection ──────────────────────────────────────────────────────────
# Everything OS-specific is decided here, once. The steps below never
# branch on the OS themselves -- they use the variables set here.
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
    case "${HOST_OS}" in
        linux)
            JOBS="$(nproc)"
            # Link GCC's own C++ runtime statically, so the finished bundle
            # runs on any Linux install regardless of its libstdc++ version.
            HOST_LDFLAGS="-static-libstdc++ -static-libgcc"
            ;;
        macos)
            JOBS="$(sysctl -n hw.ncpu)"
            HOST_LDFLAGS=""
            ;;
    esac
    # Linux ships sha256sum; macOS ships shasum. Same checksum file format.
    if   command -v sha256sum >/dev/null 2>&1; then SHA256=(sha256sum)
    elif command -v shasum    >/dev/null 2>&1; then SHA256=(shasum -a 256)
    else die "need sha256sum or shasum"; fi
    command -v curl >/dev/null 2>&1 || die "curl not found"

    # The finished toolchain for THIS host is installed here.
    STAGE_DIR="${WORK_DIR}/stage/${HOST_OS}-${HOST_ARCH}"
}

# ── Shared helpers ──────────────────────────────────────────────────────────
require_tools() {
    local tool missing=()
    for tool in "$@"; do
        command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done
    (( ${#missing[@]} == 0 )) || die "missing tools: ${missing[*]}"
}

is_done()   { [[ -f "${STAMP_DIR}/$1" ]]; }
mark_done() { mkdir -p "${STAMP_DIR}"; touch "${STAMP_DIR}/$1"; }

# run_logged <name> <dir> <command...>
# Runs the command inside <dir> with all output going to work/logs/<name>.log.
# On failure, prints the tail of that log so the terminal stays readable.
run_logged() {
    local name="$1" dir="$2"
    shift 2
    local log_file="${LOG_DIR}/${name}.log"
    mkdir -p "${LOG_DIR}"
    log "  ${name}  (log: work/logs/${name}.log)"
    if ! ( cd "${dir}" && "$@" ) >"${log_file}" 2>&1; then
        printf '\n----- last 40 lines of %s -----\n' "${log_file}" >&2
        tail -n 40 "${log_file}" >&2
        die "${name} failed"
    fi
}

# extract <archive in downloads> <top-level folder it unpacks to>
extract() {
    local archive="$1" top="$2"
    is_done "extract-${top}" && return 0
    log "extracting ${archive}"
    mkdir -p "${SRC_DIR}"
    rm -rf "${SRC_DIR:?}/${top}"
    tar -xf "${DOWNLOAD_DIR}/${archive}" -C "${SRC_DIR}"
    [[ -d "${SRC_DIR}/${top}" ]] || die "${archive} did not unpack to ${top}/"
    mark_done "extract-${top}"
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

# ── build-gcc ───────────────────────────────────────────────────────────────
step_build_gcc() {
    require_tools make cc c++ tar makeinfo

    # Never build from unverified sources.
    step_fetch

    # Host-side compiler flags (these build the COMPILER, not Genesis code).
    # -std=gnu17: newer host compilers default to C23, which older GCC and
    # binutils sources were not written for. Pinning the dialect avoids that.
    export CFLAGS="-O2 -std=gnu17"
    export CXXFLAGS="-O2"
    export LDFLAGS="${HOST_LDFLAGS}"
    # GCC's build must find the m68k binutils we install first.
    export PATH="${STAGE_DIR}/bin:${PATH}"

    extract "${BINUTILS_FILE}" "binutils-${BINUTILS_VERSION}"
    extract "${GCC_FILE}"      "gcc-${GCC_VERSION}"
    local bu_src="${SRC_DIR}/binutils-${BINUTILS_VERSION}"
    local gcc_src="${SRC_DIR}/gcc-${GCC_VERSION}"

    # GMP/MPFR/MPC: GCC's own script fetches them and checks them against
    # SHA-512 sums that ship INSIDE the gcc tarball we already verified.
    # Building them in-tree also links them statically into the compiler.
    # ISL is skipped: it only powers optional loop optimizations SGDK never uses.
    if ! is_done gcc-prereqs; then
        log "GCC prerequisites"
        run_logged gcc-prereqs "${gcc_src}" ./contrib/download_prerequisites --no-isl
        mark_done gcc-prereqs
    fi

    if ! is_done binutils; then
        log "binutils ${BINUTILS_VERSION} -> ${TARGET}"
        local bu_build="${BUILD_DIR}/binutils"
        rm -rf "${bu_build}"
        mkdir -p "${bu_build}"
        run_logged binutils-configure "${bu_build}" "${bu_src}/configure" \
            --target="${TARGET}" \
            --prefix="${STAGE_DIR}" \
            --enable-plugins \
            --disable-nls \
            --disable-werror
        run_logged binutils-make    "${bu_build}" make -j"${JOBS}"
        run_logged binutils-install "${bu_build}" make install
        mark_done binutils
    fi

    if ! is_done gcc; then
        log "gcc ${GCC_VERSION} -> ${TARGET} (${TARGET_CPU}); this is the slow one"
        local gcc_build="${BUILD_DIR}/gcc"
        rm -rf "${gcc_build}"
        mkdir -p "${gcc_build}"
        # Bare-metal C compiler for the 68000 only: no OS, no C library,
        # no threads. LTO stays on because SGDK's release builds use it.
        run_logged gcc-configure "${gcc_build}" "${gcc_src}/configure" \
            --target="${TARGET}" \
            --prefix="${STAGE_DIR}" \
            --with-cpu="${TARGET_CPU}" \
            --enable-languages=c \
            --enable-lto \
            --without-headers \
            --disable-multilib \
            --disable-shared \
            --disable-threads \
            --disable-nls \
            --disable-werror \
            --disable-libssp \
            --disable-libquadmath \
            --disable-libgomp \
            --disable-libatomic
        run_logged gcc-make    "${gcc_build}" make -j"${JOBS}" all-gcc all-target-libgcc
        run_logged gcc-install "${gcc_build}" make install-gcc install-target-libgcc
        mark_done gcc
    fi

    verify_gcc
    log "build-gcc finished: ${STAGE_DIR}"
}

# Proves the compiler is really usable for SGDK, not just that it exists:
#   - compiles for the 68000,
#   - links through the LTO plugin (SGDK release builds depend on it),
#   - pulls __mulsi3 from libgcc (the 68000 has no 32-bit multiply).
verify_gcc() {
    local gcc_bin="${STAGE_DIR}/bin/${TARGET}-gcc"
    local objdump_bin="${STAGE_DIR}/bin/${TARGET}-objdump"
    local nm_bin="${STAGE_DIR}/bin/${TARGET}-nm"
    local dir="${WORK_DIR}/verify"
    rm -rf "${dir}"
    mkdir -p "${dir}"
    cat > "${dir}/probe.c" <<'PROBE'
int square(int x) { return x * x; }
void entry(void) { volatile int r = square(7); (void)r; }
PROBE
    run_logged verify-compile "${dir}" "${gcc_bin}" -m68000 -O2 -flto -fuse-linker-plugin \
        -nostdlib -Wl,-e,entry probe.c -o probe.elf -lgcc
    "${objdump_bin}" -f "${dir}/probe.elf" | grep -q "elf32-m68k" \
        || die "probe.elf is not a 68000 ELF"
    "${nm_bin}" "${dir}/probe.elf" | grep -q "__mulsi3" \
        || die "libgcc was not linked (no __mulsi3)"
    log "verified: $("${gcc_bin}" -dumpversion) targets ${TARGET}, LTO + libgcc OK"
}

# ── clean ───────────────────────────────────────────────────────────────────
step_clean() {
    log "removing work/ (keeping work/downloads)"
    rm -rf "${SRC_DIR}" "${BUILD_DIR}" "${LOG_DIR}" "${STAMP_DIR}" \
           "${WORK_DIR}/stage" "${WORK_DIR}/verify"
}

# ── Entry point ─────────────────────────────────────────────────────────────
main() {
    detect_host
    local step="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "${step}" in
        fetch)     step_fetch "$@" ;;
        build-gcc) step_build_gcc "$@" ;;
        clean)     step_clean ;;
        *)         die "usage: scripts/build_toolchain.sh fetch [--record] | build-gcc | clean" ;;
    esac
}

main "$@"