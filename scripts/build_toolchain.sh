#!/usr/bin/env bash
# build_toolchain.sh -- builds the ClassicBEU Genesis toolchain bundle.
#
# Usage:
#   scripts/build_toolchain.sh fetch [--record | --record-missing]
#                                                download + verify the pinned sources
#   scripts/build_toolchain.sh build-gcc         build binutils + GCC for the 68000
#   scripts/build_toolchain.sh build-sh2         build binutils + GCC for the 32X's SH-2s
#   scripts/build_toolchain.sh build-sh2-windows the SH-2 compiler for Windows (needs build-sh2)
#   scripts/build_toolchain.sh build-sgdk        build SGDK's tools + library, then a test ROM
#   scripts/build_toolchain.sh build-dc          build the Dreamcast's SH-4 compiler + KallistiOS
#   scripts/build_toolchain.sh package           bundle this machine's toolchain into out/
#   scripts/build_toolchain.sh package-windows   repack SGDK's Windows build into out/
#   scripts/build_toolchain.sh clean             delete work/ except downloads
#
# Each step can be re-run safely: finished sub-steps are remembered in
# work/stamps and skipped. All scratch output goes to work/ (git-ignored).
# Versions, URLs and target settings live in versions.env -- never here.
#
# Written for bash 3.2 as well as newer bash: macOS still ships bash 3.2.
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
readonly PATCH_DIR="${REPO_ROOT}/patches"

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
            # Linux builds use the zlib copy bundled with GCC/binutils.
            HOST_CONFIGURE_FLAGS=""
            ;;
        macos)
            JOBS="$(sysctl -n hw.ncpu)"
            HOST_LDFLAGS=""
            # The zlib copy bundled with GCC 13 / binutils 2.41 does not
            # compile against recent macOS SDKs; macOS always ships zlib.
            HOST_CONFIGURE_FLAGS="--with-system-zlib"
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
# On failure, shows the ERROR lines first (with line numbers), then a short
# tail. Parallel builds (make -j) keep printing after the real failure, so
# the tail alone usually shows the wrong thing.
run_logged() {
    local name="$1" dir="$2"
    shift 2
    local log_file="${LOG_DIR}/${name}.log"
    mkdir -p "${LOG_DIR}"
    log "  ${name}  (log: work/logs/${name}.log)"
    if ! ( cd "${dir}" && "$@" ) >"${log_file}" 2>&1; then
        printf '\n----- error lines in %s -----\n' "${log_file}" >&2
        grep -n -E "error:|Error [0-9]+|\*\*\*" "${log_file}" | head -n 30 >&2 \
            || printf '(no lines matched; see the tail below)\n' >&2
        printf '\n----- last 15 lines -----\n' >&2
        tail -n 15 "${log_file}" >&2
        die "${name} failed -- full log: work/logs/${name}.log"
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

# apply_patches <source dir> <patch file...>
# Applies our own small source fixes from patches/ to an unpacked tree.
# Each file says at its top what it fixes and where the fix came from.
apply_patches() {
    local dir="$1" p
    shift
    for p in "$@"; do
        log "patching $(basename "${dir}") with ${p}"
        patch -p1 -N -s -d "${dir}" < "${PATCH_DIR}/${p}" \
            || die "patch ${p} did not apply to ${dir}"
    done
}

# ── fetch ───────────────────────────────────────────────────────────────────
# Downloads to "<file>.part" and renames only on success, so an interrupted
# download never looks finished. Files already present are not re-downloaded.
# The progress bar is shown only in a live terminal; in CI logs it would be
# pages of noise, so there curl stays quiet and prints errors only.
download() {
    local file="$1" url="$2"
    local dest="${DOWNLOAD_DIR}/${file}"
    if [[ -f "${dest}" ]]; then log "already have ${file}"; return 0; fi
    log "downloading ${file}"
    local progress="--silent --show-error"
    [[ -t 2 ]] && progress="--progress-bar"
    # ${progress} is deliberately unquoted: it holds one or two flags.
    curl --fail --location --retry 3 ${progress} --output "${dest}.part" "${url}"
    mv "${dest}.part" "${dest}"
}

step_fetch() {
    local record=0 missing=0 arg
    for arg in "$@"; do
        case "${arg}" in
            --record)         record=1 ;;
            --record-missing) missing=1 ;;
            *)                die "unknown option for fetch: ${arg}" ;;
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
    if (( missing )); then
        # Pins only what has no checksum yet (a source added to ARTIFACTS);
        # every existing pin is kept, and still checked below.
        for f in "${files[@]}"; do
            grep -qF "  ${f}" "${CHECKSUMS_FILE}" && continue
            ( cd "${DOWNLOAD_DIR}" && "${SHA256[@]}" "${f}" ) | tee -a "${CHECKSUMS_FILE}"
            log "pinned ${f} -- review the line above, then commit checksums.sha256"
        done
    fi
    for f in "${files[@]}"; do
        grep -qF "  ${f}" "${CHECKSUMS_FILE}" || die "${f} has no pinned checksum"
    done
    ( cd "${DOWNLOAD_DIR}" && "${SHA256[@]}" -c "${CHECKSUMS_FILE}" ) \
        || die "checksum mismatch -- delete the FAILED file from work/downloads and re-run"
    log "all sources verified on ${HOST_OS}-${HOST_ARCH}"
}

# ── build-gcc ───────────────────────────────────────────────────────────────
# prepare_compiler_sources
# What both compilers (68000 and SH-2) build from: the verified GCC and
# binutils sources, unpacked and patched once, with GCC's prerequisites, and
# the host compiler flags. Safe to call again: each part is stamped.
prepare_compiler_sources() {
    # Never build from unverified sources.
    step_fetch

    # Host-side compiler flags (these build the COMPILER, not Genesis code).
    # Pin BOTH language dialects to what GCC 13.2's sources were written for.
    # Newer host compilers change the defaults (C23 in GCC 15, C++20 in GCC 16)
    # and those break older sources. C++ must be exactly gnu++11: libcody's
    # configure rejects anything else (it checks __cplusplus == 201103).
    export CFLAGS="-O2 -std=gnu17"
    export CXXFLAGS="-O2 -std=gnu++11"
    export LDFLAGS="${HOST_LDFLAGS}"
    # GCC's build must find the binutils we install first (both targets'
    # land in the same stage).
    export PATH="${STAGE_DIR}/bin:${PATH}"

    extract "${BINUTILS_FILE}" "binutils-${BINUTILS_VERSION}"
    extract "${GCC_FILE}"      "gcc-${GCC_VERSION}"
    local gcc_src="${SRC_DIR}/gcc-${GCC_VERSION}"

    # Our fixes to the GCC source (GCC_PATCHES in versions.env), applied once
    # right after unpacking. The count check keeps an empty list safe on bash 3.2.
    if ! is_done gcc-patches; then
        if (( ${#GCC_PATCHES[@]} > 0 )); then
            apply_patches "${gcc_src}" "${GCC_PATCHES[@]}"
        fi
        mark_done gcc-patches
    fi

    # GMP/MPFR/MPC: GCC's own script fetches them and checks them against
    # SHA-512 sums that ship INSIDE the gcc tarball we already verified.
    # Building them in-tree also links them statically into the compiler.
    # ISL is skipped: it only powers optional loop optimizations SGDK never uses.
    if ! is_done gcc-prereqs; then
        log "GCC prerequisites"
        run_logged gcc-prereqs "${gcc_src}" ./contrib/download_prerequisites --no-isl
        mark_done gcc-prereqs
    fi
}

step_build_gcc() {
    require_tools make cc c++ tar makeinfo patch
    prepare_compiler_sources
    local bu_src="${SRC_DIR}/binutils-${BINUTILS_VERSION}"
    local gcc_src="${SRC_DIR}/gcc-${GCC_VERSION}"

    if ! is_done binutils; then
        log "binutils ${BINUTILS_VERSION} -> ${TARGET}"
        local bu_build="${BUILD_DIR}/binutils"
        rm -rf "${bu_build}"
        mkdir -p "${bu_build}"
        # HOST_CONFIGURE_FLAGS is deliberately unquoted: it may be empty or several flags.
        run_logged binutils-configure "${bu_build}" "${bu_src}/configure" \
            --target="${TARGET}" \
            --prefix="${STAGE_DIR}" \
            --enable-plugins \
            --disable-nls \
            --disable-werror \
            ${HOST_CONFIGURE_FLAGS}
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
        # HOST_CONFIGURE_FLAGS is deliberately unquoted (see binutils above).
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
            --disable-libatomic \
            ${HOST_CONFIGURE_FLAGS}
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
/* volatile: the compiler must read these at runtime, so it cannot
   pre-compute the multiply -- the 68000 then needs libgcc's __mulsi3. */
volatile int probe_input = 7;
volatile int probe_result;
void entry(void) { probe_result = probe_input * probe_input; }
PROBE
    run_logged verify-compile "${dir}" "${gcc_bin}" -m68000 -O2 -flto -fuse-linker-plugin \
        -nostdlib -Wl,-e,entry probe.c -o probe.elf -lgcc
    "${objdump_bin}" -f "${dir}/probe.elf" | grep -q "elf32-m68k" \
        || die "probe.elf is not a 68000 ELF"
    "${nm_bin}" "${dir}/probe.elf" | grep -q "__mulsi3" \
        || die "libgcc was not linked (no __mulsi3)"
    log "verified: $("${gcc_bin}" -dumpversion) targets ${TARGET}, LTO + libgcc OK"
}

# ── build-sh2 ───────────────────────────────────────────────────────────────
# The 32X's two SH-2s run their own code: binutils and GCC for SH2_TARGET
# (versions.env), from the same sources and with the same choices as the
# 68000 compiler (C only, no OS, no C library, LTO on), installed into the
# same stage so the bundle's gcc/bin holds both (m68k-elf-*, sh-elf-*).
step_build_sh2() {
    require_tools make cc c++ tar makeinfo patch
    prepare_compiler_sources
    local bu_src="${SRC_DIR}/binutils-${BINUTILS_VERSION}"
    local gcc_src="${SRC_DIR}/gcc-${GCC_VERSION}"

    if ! is_done binutils-sh2; then
        log "binutils ${BINUTILS_VERSION} -> ${SH2_TARGET}"
        local bu_build="${BUILD_DIR}/binutils-sh2"
        rm -rf "${bu_build}"
        mkdir -p "${bu_build}"
        # HOST_CONFIGURE_FLAGS is deliberately unquoted (see build-gcc).
        run_logged binutils-sh2-configure "${bu_build}" "${bu_src}/configure" \
            --target="${SH2_TARGET}" \
            --prefix="${STAGE_DIR}" \
            --enable-plugins \
            --disable-nls \
            --disable-werror \
            ${HOST_CONFIGURE_FLAGS}
        run_logged binutils-sh2-make    "${bu_build}" make -j"${JOBS}"
        run_logged binutils-sh2-install "${bu_build}" make install
        mark_done binutils-sh2
    fi

    if ! is_done gcc-sh2; then
        log "gcc ${GCC_VERSION} -> ${SH2_TARGET} (${SH2_TARGET_CPU}); the slow one again"
        local gcc_build="${BUILD_DIR}/gcc-sh2"
        rm -rf "${gcc_build}"
        mkdir -p "${gcc_build}"
        run_logged gcc-sh2-configure "${gcc_build}" "${gcc_src}/configure" \
            "${SH2_GCC_CONFIGURE_FLAGS[@]}" \
            --prefix="${STAGE_DIR}" \
            ${HOST_CONFIGURE_FLAGS}
        run_logged gcc-sh2-make    "${gcc_build}" make -j"${JOBS}" all-gcc all-target-libgcc
        run_logged gcc-sh2-install "${gcc_build}" make install-gcc install-target-libgcc
        mark_done gcc-sh2
    fi

    verify_sh2_gcc "${STAGE_DIR}/bin/${SH2_TARGET}-"
    log "build-sh2 finished: ${STAGE_DIR}"
}

# What GCC is configured with for the SH-2 (here and for Windows): the 32X's
# SH7604s, big-endian, bare metal, C only. One CPU, so one libgcc (m2).
SH2_GCC_CONFIGURE_FLAGS=(
    --target="${SH2_TARGET}"
    --with-cpu="${SH2_TARGET_CPU}"
    --with-multilib-list="${SH2_TARGET_CPU}"
    --enable-languages=c
    --enable-lto
    --without-headers
    --disable-shared
    --disable-threads
    --disable-nls
    --disable-werror
    --disable-libssp
    --disable-libquadmath
    --disable-libgomp
    --disable-libatomic
)

# verify_sh2_gcc <tool path prefix, e.g. .../bin/sh-elf->
# Proves the SH-2 compiler is usable, as verify_gcc does for the 68000:
#   - compiles for the SH-2 (big-endian SH ELF),
#   - links through the LTO plugin,
#   - pulls a divide from libgcc (the SH-2 has no single divide instruction).
verify_sh2_gcc() {
    local prefix="$1"
    local dir="${WORK_DIR}/verify-sh2"
    rm -rf "${dir}"
    mkdir -p "${dir}"
    cat > "${dir}/probe.c" <<'PROBE'
/* volatile: computed at run time, so the divide needs libgcc. */
volatile int probe_a = 1000, probe_b = 7;
volatile int probe_result;
void entry(void) { probe_result = probe_a / probe_b; }
PROBE
    run_logged verify-sh2-compile "${dir}" "${prefix}gcc" -"${SH2_TARGET_CPU}" -mb -O2 -flto -fuse-linker-plugin \
        -nostdlib -Wl,-e,_entry probe.c -o probe.elf -lgcc
    "${prefix}objdump" -f "${dir}/probe.elf" | grep -q "elf32-sh" \
        || die "probe.elf is not an SH ELF"
    "${prefix}nm" "${dir}/probe.elf" | grep -q "divsi3" \
        || die "libgcc was not linked (no divide routine)"
    log "verified: $("${prefix}gcc" -dumpversion) targets ${SH2_TARGET} (${SH2_TARGET_CPU}), LTO + libgcc OK"
}

# ── build-sh2-windows ───────────────────────────────────────────────────────
# The Windows bundle is SGDK's own Windows build, which has no SH-2 compiler.
# This builds one for Windows ON LINUX (a "Canadian cross": built here, runs
# on Windows, makes SH-2 code) with the MinGW-w64 compiler, into its own
# stage. libgcc is SH-2 code, the same whatever runs the compiler, so it is
# copied from the Linux build (build-sh2) instead of being built twice.
# Like package-windows, nothing here can run on Linux: the Windows CI job
# test-compiles with it.
readonly MINGW_HOST="x86_64-w64-mingw32"

step_build_sh2_windows() {
    require_tools make tar makeinfo "${MINGW_HOST}-gcc" "${MINGW_HOST}-g++"
    [[ "${HOST_OS}" == "linux" ]] || die "build-sh2-windows runs on Linux only"
    is_done gcc-sh2 || die "run build-sh2 first (its libgcc and assembler are needed)"
    prepare_compiler_sources
    # Windows programs that need no MinGW DLLs beside them: the C and C++
    # runtimes linked in. Not plain -static: that stops libtool making any
    # DLL, and the LTO linker plugin (liblto_plugin.dll) is one.
    export LDFLAGS="-static-libgcc -static-libstdc++"
    local bu_src="${SRC_DIR}/binutils-${BINUTILS_VERSION}"
    local gcc_src="${SRC_DIR}/gcc-${GCC_VERSION}"
    local stage="${WORK_DIR}/stage/windows-x64-sh2"

    if ! is_done binutils-sh2-windows; then
        log "binutils ${BINUTILS_VERSION} -> ${SH2_TARGET}, for Windows"
        local bu_build="${BUILD_DIR}/binutils-sh2-windows"
        rm -rf "${bu_build}"
        mkdir -p "${bu_build}"
        run_logged binutils-sh2-windows-configure "${bu_build}" "${bu_src}/configure" \
            --host="${MINGW_HOST}" \
            --target="${SH2_TARGET}" \
            --prefix="${stage}" \
            --enable-plugins \
            --disable-nls \
            --disable-werror \
            --disable-gdb --disable-gprofng
        run_logged binutils-sh2-windows-make    "${bu_build}" make -j"${JOBS}"
        run_logged binutils-sh2-windows-install "${bu_build}" make install
        mark_done binutils-sh2-windows
    fi

    if ! is_done gcc-sh2-windows; then
        log "gcc ${GCC_VERSION} -> ${SH2_TARGET}, for Windows"
        local gcc_build="${BUILD_DIR}/gcc-sh2-windows"
        rm -rf "${gcc_build}"
        mkdir -p "${gcc_build}"
        run_logged gcc-sh2-windows-configure "${gcc_build}" "${gcc_src}/configure" \
            --host="${MINGW_HOST}" \
            "${SH2_GCC_CONFIGURE_FLAGS[@]}" \
            --prefix="${stage}"
        run_logged gcc-sh2-windows-make    "${gcc_build}" make -j"${JOBS}" all-gcc
        run_logged gcc-sh2-windows-install "${gcc_build}" make install-gcc
        # libgcc and its headers: SH-2 code, from the Linux build.
        local libdir="lib/gcc/${SH2_TARGET}/${GCC_VERSION}"
        mkdir -p "${stage}/${libdir}"
        cp -R "${STAGE_DIR}/${libdir}/." "${stage}/${libdir}/"
        rm -rf "${stage}/share"   # manual pages only
        mark_done gcc-sh2-windows
    fi
    [[ -f "${stage}/bin/${SH2_TARGET}-gcc.exe" && -f "${stage}/lib/gcc/${SH2_TARGET}/${GCC_VERSION}/libgcc.a" ]] \
        || die "the Windows SH-2 compiler is incomplete in ${stage}"
    [[ -f "${stage}/libexec/gcc/${SH2_TARGET}/${GCC_VERSION}/liblto_plugin.dll" ]] \
        || die "the Windows SH-2 compiler has no LTO plugin (liblto_plugin.dll)"
    log "build-sh2-windows finished: ${stage} (NOT test-run; the Windows CI job does that)"
}

# ── build-dc ────────────────────────────────────────────────────────────────
# The Dreamcast: its SH-4 compiler (C and C++) with newlib and KallistiOS's
# threads, and KallistiOS itself, built the way KallistiOS's kos-chain builds
# them (binutils, GCC pass 1, newlib, GCC pass 2), from the same GCC and
# binutils sources as the other compilers. Everything goes in its own stage,
# the bundle's dreamcast/ folder:
#   sh-elf/       the compiler (KallistiOS's KOS_CC_BASE)
#   kos/          KallistiOS, built (KOS_BASE), with makeip for disc images
#   environ.sh    KallistiOS's environment, wherever the bundle is unpacked
# Its sh-elf compiler is not the 32X's (same name, another CPU), so the two
# never share a bin folder.
dc_stage()   { printf '%s' "${WORK_DIR}/stage/${HOST_OS}-${HOST_ARCH}-dreamcast"; }

# write_dc_environ <dreamcast folder>
# KallistiOS's environ.sh for this bundle (its doc/environ.sh.sample, filled
# in). It finds the bundle through RGS_DREAMCAST_DIR, which whoever sources
# it sets to the dreamcast/ folder (the editor does), so the bundle works
# wherever it is unpacked.
write_dc_environ() {
    cat > "$1/environ.sh" <<ENVIRON
# KallistiOS's environment for this toolchain bundle (written by
# classicbeu-genesis-toolchain's build-dc). Set RGS_DREAMCAST_DIR to this
# folder, then source this file:
#   RGS_DREAMCAST_DIR=/path/to/bundle/dreamcast . /path/to/bundle/dreamcast/environ.sh
if [ -z "\${RGS_DREAMCAST_DIR:-}" ]; then
    echo "environ.sh: set RGS_DREAMCAST_DIR to the bundle's dreamcast folder first" >&2
    return 1 2>/dev/null || exit 1
fi
export KOS_ARCH="dreamcast"
export KOS_BASE="\${RGS_DREAMCAST_DIR}/kos"
export KOS_PORTS="\${RGS_DREAMCAST_DIR}/kos-ports"
export KOS_CC_BASE="\${RGS_DREAMCAST_DIR}/${DC_TARGET}"
export KOS_CC_PREFIX="${DC_TARGET}"
export DC_ARM_BASE="\${RGS_DREAMCAST_DIR}/arm-eabi"
export DC_ARM_PREFIX="arm-eabi"
export DC_TOOLS_BASE="\${RGS_DREAMCAST_DIR}/bin"
export KOS_CMAKE_TOOLCHAIN="\${KOS_BASE}/utils/cmake/kallistios.toolchain.cmake"
export KOS_GENROMFS="\${KOS_BASE}/utils/genromfs/genromfs"
export KOS_MAKE="make"
export KOS_LOADER="dc-tool -x"
export KOS_INC_PATHS=""
export KOS_CPPFLAGS=""
export KOS_LDFLAGS=""
export KOS_AFLAGS=""
export DC_ARM_LDFLAGS=""
export KOS_CFLAGS="-O2 -fno-PIC -fno-PIE -fomit-frame-pointer"
export KOS_SH4_PRECISION="${DC_SH4_PRECISION}"
. "\${KOS_BASE}/environ_base.sh"
ENVIRON
}

# dc_env <dreamcast folder> <command...>: runs it with KallistiOS's
# environment, and without the host compiler flags the GCC steps export
# (KallistiOS's makefiles have their own).
dc_env() {
    local dir="$1"
    shift
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS RGS_DREAMCAST_DIR="${dir}" \
        sh -c '. "${RGS_DREAMCAST_DIR}/environ.sh" && exec "$@"' dc_env "$@"
}

step_build_dc() {
    require_tools make cc c++ tar makeinfo patch
    prepare_compiler_sources
    local stage cc kos
    stage="$(dc_stage)"
    cc="${stage}/${DC_TARGET}"
    kos="${stage}/kos"
    # This compiler first: the 32X's sh-elf tools (on PATH from
    # prepare_compiler_sources) have the same names.
    export PATH="${cc}/bin:${PATH}"
    local bu_src="${SRC_DIR}/binutils-${BINUTILS_VERSION}"
    local gcc_src="${SRC_DIR}/gcc-${GCC_VERSION}-kos"
    local nl_src="${SRC_DIR}/${NEWLIB_TOP_DIR}"
    local patches="${SRC_DIR}/${KOS_TOP_DIR}/utils/kos-chain/patches"

    if ! is_done dc-sources; then
        extract "${KOS_FILE}"    "${KOS_TOP_DIR}"
        extract "${NEWLIB_FILE}" "${NEWLIB_TOP_DIR}"
        # KallistiOS is built where it is installed: copied into the stage
        # first, so its headers are there for newlib and GCC pass 2.
        rm -rf "${stage}"
        mkdir -p "${stage}"
        cp -pR "${SRC_DIR}/${KOS_TOP_DIR}" "${kos}"
        # Our fixes to it (KOS_PATCHES in versions.env); the count check
        # keeps an empty list safe on bash 3.2.
        if (( ${#KOS_PATCHES[@]} > 0 )); then
            apply_patches "${kos}" "${KOS_PATCHES[@]}"
        fi
        write_dc_environ "${stage}"
        # GCC with KallistiOS's thread model: a copy of the (already patched,
        # prerequisites in) GCC source, so the other compilers' stays as is.
        # -p keeps the files' times: without it a generated file (mpfr's
        # configure) can look older than its source, and make tries to
        # remake it with autotools, which fails.
        log "GCC and newlib sources with KallistiOS's patches"
        rm -rf "${gcc_src}"
        cp -pR "${SRC_DIR}/gcc-${GCC_VERSION}" "${gcc_src}"
        cp "${patches}/gcc/gthr-kos.h" "${gcc_src}/libgcc/gthr-kos.h"
        cp "${patches}/gcc/fake-kos.c" "${gcc_src}/libgcc/config/fake-kos.c"
        patch -p1 -N -s -d "${gcc_src}" < "${patches}/targets/${KOS_GCC_PATCH}" \
            || die "KallistiOS's ${KOS_GCC_PATCH} did not apply"
        # newlib with KallistiOS's locks and syscalls.
        mkdir -p "${nl_src}/newlib/libc/machine/sh/sys"
        cp "${kos}/include/sys/lock.h" "${nl_src}/newlib/libc/machine/sh/sys/lock.h"
        cp "${kos}/include/sys/lock.h" "${nl_src}/newlib/libc/include/sys/lock.h"
        patch -p1 -N -s -d "${nl_src}" < "${patches}/targets/${KOS_NEWLIB_PATCH}" \
            || die "KallistiOS's ${KOS_NEWLIB_PATCH} did not apply"
        mark_done dc-sources
    fi

    if ! is_done dc-binutils; then
        log "binutils ${BINUTILS_VERSION} -> ${DC_TARGET} (Dreamcast)"
        local b="${BUILD_DIR}/dc-binutils"
        rm -rf "${b}"; mkdir -p "${b}"
        # HOST_CONFIGURE_FLAGS is deliberately unquoted (see build-gcc).
        run_logged dc-binutils-configure "${b}" "${bu_src}/configure" \
            --target="${DC_TARGET}" --prefix="${cc}" \
            --disable-nls --disable-werror ${HOST_CONFIGURE_FLAGS}
        run_logged dc-binutils-make    "${b}" make -j"${JOBS}"
        run_logged dc-binutils-install "${b}" make install
        mark_done dc-binutils
    fi

    if ! is_done dc-gcc1; then
        log "gcc ${GCC_VERSION} -> ${DC_TARGET}, pass 1 (C, for newlib)"
        local b="${BUILD_DIR}/dc-gcc1"
        rm -rf "${b}"; mkdir -p "${b}"
        run_logged dc-gcc1-configure "${b}" "${gcc_src}/configure" \
            --target="${DC_TARGET}" --prefix="${cc}" "${DC_CPU_FLAGS[@]}" \
            --with-gnu-as --with-gnu-ld --without-headers --with-newlib \
            --enable-languages=c --disable-libssp --enable-checking=release \
            --disable-nls --disable-werror ${HOST_CONFIGURE_FLAGS}
        run_logged dc-gcc1-make    "${b}" make -j"${JOBS}" all-gcc all-target-libgcc
        run_logged dc-gcc1-install "${b}" make install-gcc install-target-libgcc
        mark_done dc-gcc1
    fi

    if ! is_done dc-newlib; then
        log "newlib ${NEWLIB_VERSION} -> ${DC_TARGET}"
        local b="${BUILD_DIR}/dc-newlib"
        rm -rf "${b}"; mkdir -p "${b}"
        run_logged dc-newlib-configure "${b}" "${nl_src}/configure" \
            --target="${DC_TARGET}" --prefix="${cc}" "${DC_CPU_FLAGS[@]}" \
            --disable-newlib-supplied-syscalls --enable-newlib-io-c99-formats
        run_logged dc-newlib-make    "${b}" make -j"${JOBS}"
        run_logged dc-newlib-install "${b}" make install
        # KallistiOS's fix-ups to newlib's headers (kos-chain's
        # fixup-newlib): its pthreads, dirent and timers, and its own
        # headers as <kos/...>. The link is relative, so it moves with the bundle.
        local inc="${cc}/${DC_TARGET}/include"
        mkdir -p "${inc}/sys" "${inc}/machine"
        cp "${kos}/include/pthread.h"           "${inc}/"
        cp "${kos}/include/sys/_pthreadtypes.h" "${inc}/sys/"
        cp "${kos}/include/sys/dirent.h"        "${inc}/sys/"
        cp "${kos}/include/machine/time.h"      "${inc}/machine/"
        ln -nsf "../../../kos/include/kos" "${inc}/kos"
        [[ -f "${inc}/kos/thread.h" ]] || die "newlib's kos/ link does not reach KallistiOS's headers"
        mark_done dc-newlib
    fi

    if ! is_done dc-gcc2; then
        log "gcc ${GCC_VERSION} -> ${DC_TARGET}, pass 2 (C, C++, KallistiOS threads); the slow one"
        # --disable-libcc1: GDB's "compile" plugin, which no game needs; with
        # C++ on it is built, and macOS's libc++ headers trip GCC's poisoned
        # identifiers in it.
        local b="${BUILD_DIR}/dc-gcc2"
        rm -rf "${b}"; mkdir -p "${b}"
        run_logged dc-gcc2-configure "${b}" "${gcc_src}/configure" \
            --target="${DC_TARGET}" --prefix="${cc}" "${DC_CPU_FLAGS[@]}" \
            --with-gnu-as --with-gnu-ld --with-newlib --disable-libssp \
            --enable-threads=kos --enable-languages=c,c++ --enable-checking=release \
            --with-libstdcxx-zoneinfo=no --disable-nls --disable-werror --disable-libcc1 ${HOST_CONFIGURE_FLAGS}
        run_logged dc-gcc2-make    "${b}" make -j"${JOBS}"
        run_logged dc-gcc2-install "${b}" make install
        rm -rf "${cc}/share"   # manual pages only
        mark_done dc-gcc2
    fi

    if ! is_done dc-kos; then
        # Its kernel (libkallisti) and addons, and the host tools a game's
        # build uses: genromfs (romdisks) and makeip (below). Not its other
        # utils (image converters and the like, needing libjpeg/libpng):
        # KallistiOS's top-level make would build those first.
        log "KallistiOS (${KOS_COMMIT:0:7}): kernel, addons, genromfs, makeip"
        run_logged dc-kos-genromfs "${kos}/utils/genromfs" dc_env "${stage}" make
        run_logged dc-kos          "${kos}/kernel"         dc_env "${stage}" make
        run_logged dc-kos-addons   "${kos}/addons"         dc_env "${stage}" make
        [[ -f "${kos}/lib/dreamcast/libkallisti.a" ]] || die "KallistiOS's kernel did not build (no lib/dreamcast/libkallisti.a)"
        # makeip makes a disc's boot sector (IP.BIN) with its own
        # copyright-free bootstrap (utils/makeip/README.md); no Sega code.
        # Built without libpng (KOS_PATCHES): it takes boot logos as MR images.
        run_logged dc-makeip       "${kos}/utils/makeip"   dc_env "${stage}" make
        [[ -x "${kos}/utils/makeip/makeip" ]] || die "makeip did not build"
        mark_done dc-kos
    fi

    verify_dc "${stage}"
    log "build-dc finished: ${stage}"
}

# verify_dc <dreamcast folder>
# Proves the Dreamcast toolchain works through KallistiOS's own wrappers, as
# a game is built: a C and a C++ program link against KallistiOS into
# little-endian SH ELFs, and makeip makes a boot sector.
verify_dc() {
    local root="$1"
    local dir="${WORK_DIR}/verify-dc"
    rm -rf "${dir}"
    mkdir -p "${dir}"
    cat > "${dir}/probe.c" <<'PROBE'
#include <kos.h>
int main(int argc, char** argv) { (void) argc; (void) argv; printf("probe %d\n", (int) thd_get_current()->tid); return 0; }
PROBE
    cat > "${dir}/probe.cpp" <<'PROBE'
#include <kos.h>
#include <string>
#include <vector>
int main() { std::vector<std::string> v{ "probe" }; printf("%s\n", v[0].c_str()); return 0; }
PROBE
    run_logged verify-dc-c   "${dir}" dc_env "${root}" kos-cc  -o probe.elf  probe.c
    run_logged verify-dc-cpp "${dir}" dc_env "${root}" kos-c++ -o probe2.elf probe.cpp
    local objdump="${root}/${DC_TARGET}/bin/${DC_TARGET}-objdump" nm="${root}/${DC_TARGET}/bin/${DC_TARGET}-nm" f
    # Written to files first: grep -q stops reading early, and with
    # pipefail nm's big output would then fail the pipe.
    for f in probe.elf probe2.elf; do
        "${objdump}" -f "${dir}/${f}" > "${dir}/${f}.head"
        "${nm}" "${dir}/${f}" > "${dir}/${f}.nm"
        grep -q "elf32-shl" "${dir}/${f}.head" || die "${f} is not a little-endian SH ELF"
        grep -q "arch_main" "${dir}/${f}.nm" || die "${f} was not linked with KallistiOS"
    done
    run_logged verify-dc-makeip "${dir}" "${root}/kos/utils/makeip/makeip" -g PROBE -f IP.BIN
    local size magic
    size="$(wc -c < "${dir}/IP.BIN" | tr -d ' ')"
    magic="$(dd if="${dir}/IP.BIN" bs=1 count=15 2>/dev/null)"
    [[ "${size}" == "${DC_IP_BIN_SIZE}" && "${magic}" == "${DC_IP_HARDWARE_ID}" ]] \
        || die "makeip's IP.BIN is ${size} bytes starting '${magic}'"
    log "verified: Dreamcast C and C++ programs link with KallistiOS; makeip makes IP.BIN"
}

# A Dreamcast boot sector: 16 sectors of 2048 bytes, starting with this.
readonly DC_IP_BIN_SIZE=32768
readonly DC_IP_HARDWARE_ID="SEGA SEGAKATANA"

# ── build-sgdk ──────────────────────────────────────────────────────────────
# What goes into the bundle from the SGDK source tree. Deliberately left out:
# Windows .exe/.dll files, the prebuilt Windows lib/ (we rebuild it), samples,
# docs, and the tools' source code (we compile the tools below instead).
SGDK_STAGE_ITEMS=(inc src res md.ld makefile.gen makelib.gen common.mk
                  license.txt COPYING.RUNTIME readme.md)
readonly SGDK_STAGE_ITEMS

# SGDK pads every ROM to a multiple of this (makefile.gen: sizebnd -sizealign).
readonly SGDK_ROM_ALIGN=131072
# Every Mega Drive ROM header starts with this at offset 0x100.
readonly MD_HEADER_OFFSET=256
readonly MD_HEADER_MAGIC="SEGA MEGA DRIVE"

step_build_sgdk() {
    require_tools make cc c++ tar java
    [[ -x "${STAGE_DIR}/bin/${TARGET}-gcc" ]] \
        || die "no ${TARGET}-gcc in ${STAGE_DIR}; run build-gcc first"

    # Never build from unverified sources.
    step_fetch

    extract "${SGDK_FILE}" "${SGDK_TOP_DIR}"
    local sgdk_src="${SRC_DIR}/${SGDK_TOP_DIR}"
    local sgdk_stage="${STAGE_DIR}/sgdk"
    # Our compiler first, then SGDK's host tools (makefile.gen calls sjasm,
    # bintos and convsym by bare name on Linux/macOS).
    export PATH="${STAGE_DIR}/bin:${sgdk_stage}/bin:${PATH}"

    if ! is_done sgdk-host-tools; then
        build_sgdk_host_tools "${sgdk_src}"
        mark_done sgdk-host-tools
    fi
    if ! is_done sgdk; then
        stage_sgdk "${sgdk_src}" "${sgdk_stage}"
        build_sgdk_lib "${sgdk_stage}"
        mark_done sgdk
    fi

    verify_sgdk_rom "${sgdk_stage}" release
    verify_sgdk_rom "${sgdk_stage}" debug
    log "build-sgdk finished: ${sgdk_stage}"
}

# SGDK's small helper programs, compiled for THIS machine. Each gets its
# dialect pinned for the same reason as GCC: newer host compilers change the
# defaults. convsym is the exception that genuinely needs C++20.
build_sgdk_host_tools() {
    local tools="$1/tools"
    local out="${BUILD_DIR}/host-tools"
    rm -rf "${out}"
    mkdir -p "${out}"
    log "SGDK host tools"
    # HOST_LDFLAGS is deliberately unquoted: it may be empty or several flags.
    # Z80 sound-driver assembler + its binary-to-source converter.
    run_logged tool-sjasm "${out}" c++ -std=gnu++11 -O2 -DMAX_PATH=MAXPATHLEN \
        ${HOST_LDFLAGS} -o sjasm "${tools}"/sjasm/src/*.cpp
    run_logged tool-bintos "${out}" cc -std=gnu17 -O2 \
        ${HOST_LDFLAGS} -o bintos "${tools}/bintos/src/bintos.c"
    # Legacy XGM music converter (rescomp runs it for XGM resources).
    run_logged tool-xgmtool "${out}" cc -std=gnu17 -O2 -I"${tools}/xgmtool/inc" \
        ${HOST_LDFLAGS} -o xgmtool "${tools}"/xgmtool/src/*.c -lm
    # Debug-symbol injector used by debug ROM builds.
    run_logged tool-convsym "${out}" c++ -std=c++20 -O2 -I"${tools}/convsym/include" \
        ${HOST_LDFLAGS} -o convsym "${tools}/convsym/src/main.cpp"
}

# Copies the parts of SGDK we ship into the stage, plus the host tools.
# rescomp looks for xgmtool NEXT TO rescomp.jar, so tools go in sgdk/bin.
stage_sgdk() {
    local src="$1" stage="$2" item
    log "staging SGDK into ${stage}"
    rm -rf "${stage}"
    mkdir -p "${stage}/bin" "${stage}/lib"
    for item in "${SGDK_STAGE_ITEMS[@]}"; do
        cp -R "${src}/${item}" "${stage}/"
    done
    cp "${src}"/bin/*.jar "${src}"/bin/*.txt "${stage}/bin/"
    cp "${BUILD_DIR}"/host-tools/* "${stage}/bin/"
}

# Rebuilds libmd.a (release) and libmd_debug.a with OUR compiler, using
# SGDK's own library makefile. Both variants compile to the same .o paths,
# so object files are cleaned between them and afterwards.
build_sgdk_lib() {
    local stage="$1"
    local mk=(make -f "${stage}/makelib.gen" GDK="${stage}" PREFIX="${TARGET}-")
    log "SGDK library (release + debug)"
    run_logged sgdk-lib-release       "${stage}" "${mk[@]}" -j"${JOBS}" release
    run_logged sgdk-lib-tidy-release  "${stage}" "${mk[@]}" cleanobj cleandep
    run_logged sgdk-lib-debug         "${stage}" "${mk[@]}" -j"${JOBS}" debug
    run_logged sgdk-lib-tidy-debug    "${stage}" "${mk[@]}" cleanobj cleandep
    # sjasm drops its assembly listing in the working directory; not shipped.
    rm -f "${stage}/out.lst"
    [[ -f "${stage}/lib/libmd.a" && -f "${stage}/lib/libmd_debug.a" ]] \
        || die "SGDK library build produced no libmd.a / libmd_debug.a"
}

# check_rom <rom file> <label>
# Checks a finished ROM: it exists, its size is a multiple of SGDK's padding,
# and its header starts with the Mega Drive signature. <label> names the ROM
# in the success and error messages.
check_rom() {
    local rom="$1" label="$2"
    [[ -f "${rom}" ]] || die "${label}: no ROM produced"
    local size
    size="$(wc -c < "${rom}" | tr -d ' ')"
    (( size > 0 && size % SGDK_ROM_ALIGN == 0 )) \
        || die "${label}: ROM size ${size} is not a multiple of ${SGDK_ROM_ALIGN}"
    local magic
    magic="$(dd if="${rom}" bs=1 skip="${MD_HEADER_OFFSET}" count="${#MD_HEADER_MAGIC}" 2>/dev/null)"
    [[ "${magic}" == "${MD_HEADER_MAGIC}" ]] \
        || die "${label}: ROM header is '${magic}', expected '${MD_HEADER_MAGIC}'"
    log "verified: ${label} (${size} bytes, header OK)"
}

# End-to-end proof: an empty project folder makes SGDK generate its own
# hello-world main.c, which we build into a real ROM and sanity-check.
verify_sgdk_rom() {
    local stage="$1" config="$2"
    local dir="${WORK_DIR}/verify-rom-${config}"
    rm -rf "${dir}"
    mkdir -p "${dir}"
    run_logged "verify-rom-${config}" "${dir}" \
        make -f "${stage}/makefile.gen" GDK="${stage}" PREFIX="${TARGET}-" "${config}"

    check_rom "${dir}/out/rom.bin" "${config} ROM builds"
}

# ── package ─────────────────────────────────────────────────────────────────
# Assembles this machine's toolchain into one folder with a fixed layout,
#   gcc/   the 68000 compiler      sgdk/   SGDK      java/   Java
# checks it works on its own, then compresses it into out/ for release.
readonly BUNDLE_DIR="${WORK_DIR}/bundle"
readonly OUT_DIR="${REPO_ROOT}/out"

bundle_name() { printf 'classicbeu-genesis-%s-%s' "${TOOLCHAIN_ID}" "$1"; }

# Which pinned Java archive belongs to a host. Unknown hosts fail loudly.
jre_file_for() {
    case "$1" in
        linux-x64)   printf '%s' "${JRE_FILE_LINUX_X64}" ;;
        macos-arm64) printf '%s' "${JRE_FILE_MACOS_ARM64}" ;;
        windows-x64) printf '%s' "${JRE_FILE_WINDOWS_X64}" ;;
        *)           die "no Java pinned for host $1 (add one to versions.env)" ;;
    esac
}

# unpack_jre <host> <bundle folder>  ->  <bundle folder>/java
unpack_jre() {
    local host="$1" root="$2" file
    file="$(jre_file_for "${host}")"
    local tmp="${WORK_DIR}/jre-unpack"
    rm -rf "${tmp}"
    mkdir -p "${tmp}"
    # Linux/macOS Java comes as .tar.gz; Windows Java comes as .zip,
    # which tar cannot open on every system, so it gets unzip.
    case "${file}" in
        *.zip) unzip -q "${DOWNLOAD_DIR}/${file}" -d "${tmp}" ;;
        *)     tar -xf "${DOWNLOAD_DIR}/${file}" -C "${tmp}" ;;
    esac
    [[ -d "${tmp}/${JRE_TOP_DIR}" ]] || die "${file} did not unpack to ${JRE_TOP_DIR}/"
    mv "${tmp}/${JRE_TOP_DIR}" "${root}/java"
    rm -rf "${tmp}"
}

# Where the java executable sits inside a bundle, per host. The macOS
# Java is packaged app-style, so its binary is under Contents/Home.
java_exe_for() {
    case "$1" in
        linux-*)   printf 'java/bin/java' ;;
        macos-*)   printf 'java/Contents/Home/bin/java' ;;
        windows-*) printf 'java/bin/java.exe' ;;
        *)         die "unknown host $1" ;;
    esac
}

# write_manifest <bundle folder> <host> <compiler bin dir> <tool prefix> <java exe> <SH-2 bin dir> [<Dreamcast dir>]
# Writes toolchain.json: the editor's map of this bundle. Every path is
# relative to the bundle folder and uses forward slashes on every OS.
# "sh2" is the 32X's compiler (SH2_TARGET- tools in its binDir).
# "dreamcast" (when the bundle has it) is KallistiOS and its compiler:
# environ.sh is sourced with RGS_DREAMCAST_DIR set to its dir.
write_manifest() {
    local root="$1" host="$2" gcc_bin="$3" prefix="$4" java_exe="$5" sh2_bin="$6" dc_dir="${7:-}"
    local dc=""
    [[ -n "${dc_dir}" ]] && dc=",
  \"dreamcast\": { \"dir\": \"${dc_dir}\", \"environ\": \"${dc_dir}/environ.sh\", \"kos\": \"${KOS_COMMIT}\",
                 \"gcc\": \"${GCC_VERSION}\", \"newlib\": \"${NEWLIB_VERSION}\", \"makeip\": \"${dc_dir}/kos/utils/makeip/makeip\" }"
    cat > "${root}/toolchain.json" <<MANIFEST
{
  "schema": ${TOOLCHAIN_MANIFEST_SCHEMA},
  "id": "${TOOLCHAIN_ID}",
  "host": "${host}",
  "sgdk": { "version": "${SGDK_TAG#v}", "dir": "sgdk" },
  "gcc":  { "version": "${GCC_VERSION}", "binDir": "${gcc_bin}", "prefix": "${prefix}",
            "target": "${TARGET}", "cpu": "${TARGET_CPU}" },
  "sh2":  { "version": "${GCC_VERSION}", "binDir": "${sh2_bin}", "prefix": "${SH2_TARGET}-",
            "target": "${SH2_TARGET}", "cpu": "${SH2_TARGET_CPU}" },
  "java": { "version": "${JRE_VERSION}", "exe": "${java_exe}" }${dc}
}
MANIFEST
}

# verify_bundle <bundle folder> <host>
# Proves the bundle works on its own, in two stages:
#  1. The bundle's GCC finds its own internal files inside the bundle. GCC
#     was installed into work/stage and then copied; if it still looked in
#     work/stage, the ROM build below would pass here but fail on every
#     other machine. These queries print where GCC really looks.
#  2. SGDK's hello-world ROM builds using only the bundle's compiler, SGDK
#     and Java. PATH is replaced for that one command: bundle folders first,
#     then the folder of the `make` this build already uses (Homebrew's GNU
#     make on macOS), then /usr/bin and /bin for basic commands.
verify_bundle() {
    local root="$1" host="$2"
    local gcc_bin="${root}/gcc/bin/${TARGET}-gcc" query found
    for query in -print-libgcc-file-name -print-prog-name=cc1 \
                 -print-prog-name=ld -print-prog-name=lto-wrapper; do
        found="$("${gcc_bin}" "${query}")"
        [[ "${found}" == "${root}/"* ]] \
            || die "bundle GCC resolves ${query} to '${found}', which is outside the bundle"
    done
    log "verified: bundle GCC finds its own files inside the bundle"
    local sh2_gcc="${root}/gcc/bin/${SH2_TARGET}-gcc"
    for query in -print-libgcc-file-name -print-prog-name=cc1 \
                 -print-prog-name=ld -print-prog-name=lto-wrapper; do
        found="$("${sh2_gcc}" "${query}")"
        [[ "${found}" == "${root}/"* ]] \
            || die "bundle SH-2 GCC resolves ${query} to '${found}', which is outside the bundle"
    done
    verify_sh2_gcc "${root}/gcc/bin/${SH2_TARGET}-"
    log "verified: bundle SH-2 GCC finds its own files inside the bundle"
    local dc_gcc="${root}/dreamcast/${DC_TARGET}/bin/${DC_TARGET}-gcc"
    for query in -print-libgcc-file-name -print-prog-name=cc1 -print-prog-name=cc1plus \
                 -print-prog-name=ld -print-file-name=libc.a -print-file-name=libstdc++.a; do
        found="$("${dc_gcc}" "${query}")"
        [[ "${found}" == "${root}/"* ]] \
            || die "bundle Dreamcast GCC resolves ${query} to '${found}', which is outside the bundle"
    done
    verify_dc "${root}/dreamcast"
    log "verified: bundle Dreamcast GCC and KallistiOS work from inside the bundle"

    local java_exe java_bin_dir make_dir
    java_exe="$(java_exe_for "${host}")"
    java_bin_dir="$(dirname "${root}/${java_exe}")"
    make_dir="$(dirname "$(command -v make)")"
    local dir="${WORK_DIR}/verify-bundle"
    rm -rf "${dir}"
    mkdir -p "${dir}"
    run_logged verify-bundle "${dir}" \
        env PATH="${root}/gcc/bin:${root}/sgdk/bin:${java_bin_dir}:${make_dir}:/usr/bin:/bin" \
        make -f "${root}/sgdk/makefile.gen" GDK="${root}/sgdk" PREFIX="${TARGET}-" release
    check_rom "${dir}/out/rom.bin" "ROM built from the bundle alone"
}

# write_checksum <archive>
# Writes <archive>.sha256 beside it, in the same "<hash>  <file name>" format
# as checksums.sha256, so anyone can check a download with sha256sum -c.
write_checksum() {
    local archive="$1"
    ( cd "$(dirname "${archive}")" && "${SHA256[@]}" "$(basename "${archive}")" ) > "${archive}.sha256"
}

step_package() {
    require_tools tar xz
    local host="${HOST_OS}-${HOST_ARCH}"
    is_done sgdk || die "nothing to package yet; run build-gcc and build-sgdk first"
    is_done gcc-sh2 || die "no SH-2 compiler yet; run build-sh2 first"
    is_done dc-kos || die "no Dreamcast toolchain yet; run build-dc first"
    step_fetch

    local name root entry
    name="$(bundle_name "${host}")"
    root="${BUNDLE_DIR}/${name}"
    log "assembling ${name}"
    rm -rf "${root}"
    mkdir -p "${root}/gcc"
    # Everything GCC installed into the stage, except the sgdk folder.
    for entry in "${STAGE_DIR}"/*; do
        [[ "$(basename "${entry}")" == "sgdk" ]] && continue
        cp -R "${entry}" "${root}/gcc/"
    done
    rm -rf "${root}/gcc/share"   # manual pages only; not needed to compile
    cp -R "${STAGE_DIR}/sgdk" "${root}/sgdk"
    # The Dreamcast's (cp -R keeps newlib's relative kos/ link a link).
    cp -R "$(dc_stage)" "${root}/dreamcast"
    unpack_jre "${host}" "${root}"
    local java_exe
    java_exe="$(java_exe_for "${host}")"
    write_manifest "${root}" "${host}" "gcc/bin" "${TARGET}-" "${java_exe}" "gcc/bin" "dreamcast"
    verify_bundle "${root}" "${host}"
    log "bundle folder ready: work/bundle/${name}"

    mkdir -p "${OUT_DIR}"
    local archive="${OUT_DIR}/${name}.tar.xz"
    rm -f "${archive}" "${archive}.sha256"
    log "compressing out/${name}.tar.xz (takes a minute or two)"
    tar -C "${BUNDLE_DIR}" -cJf "${archive}" "${name}"
    write_checksum "${archive}"
    log "package finished: out/${name}.tar.xz"
}

# step_package_windows
# Builds the Windows bundle ON LINUX by repacking SGDK's own Windows build:
# its bin/ already holds GCC 13.2 for Windows (gcc.exe, cc1.exe, ld.exe...),
# make.exe and sh.exe, and its lib/ holds libmd.a built with that compiler.
# We add the Windows Java and toolchain.json. Windows .exe files cannot run
# here, so this bundle is NOT test-built; the Windows CI job does that.
step_package_windows() {
    require_tools zip unzip
    local host="windows-x64"
    step_fetch
    extract "${SGDK_FILE}" "${SGDK_TOP_DIR}"
    local sgdk_src="${SRC_DIR}/${SGDK_TOP_DIR}"

    local name root item
    name="$(bundle_name "${host}")"
    root="${BUNDLE_DIR}/${name}"
    log "assembling ${name} (repack of SGDK's Windows build)"
    rm -rf "${root}"
    mkdir -p "${root}/sgdk"
    # The same SGDK parts as the Linux bundle, plus SGDK's own bin/ and lib/,
    # which hold the Windows compiler, tools and prebuilt library.
    for item in "${SGDK_STAGE_ITEMS[@]}" bin lib; do
        cp -R "${sgdk_src}/${item}" "${root}/sgdk/"
    done
    # The 32X's SH-2 compiler, built for Windows here (build-sh2-windows).
    is_done gcc-sh2-windows || die "no Windows SH-2 compiler yet; run build-sh2-windows first"
    cp -R "${WORK_DIR}/stage/windows-x64-sh2" "${root}/sh2"
    unpack_jre "${host}" "${root}"
    local java_exe
    java_exe="$(java_exe_for "${host}")"
    # SGDK's Windows compiler lives in sgdk/bin and its tools have no prefix.
    write_manifest "${root}" "${host}" "sgdk/bin" "" "${java_exe}" "sh2/bin"
    log "bundle folder ready: work/bundle/${name}"

    mkdir -p "${OUT_DIR}"
    local archive="${OUT_DIR}/${name}.zip"
    rm -f "${archive}" "${archive}.sha256"
    log "compressing out/${name}.zip"
    ( cd "${BUNDLE_DIR}" && zip -qr "${archive}" "${name}" )
    write_checksum "${archive}"
    log "package-windows finished: out/${name}.zip (NOT test-built; the Windows CI job verifies it)"
}

# ── clean ───────────────────────────────────────────────────────────────────
step_clean() {
    log "removing work/ except work/downloads (out/ is not touched)"
    rm -rf "${SRC_DIR}" "${BUILD_DIR}" "${LOG_DIR}" "${STAMP_DIR}" \
           "${WORK_DIR}/stage" "${WORK_DIR}"/verify* \
           "${BUNDLE_DIR}" "${WORK_DIR}/jre-unpack"
}

# ── Entry point ─────────────────────────────────────────────────────────────
main() {
    detect_host
    local step="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "${step}" in
        fetch)           step_fetch "$@" ;;
        build-gcc)       step_build_gcc "$@" ;;
        build-sh2)       step_build_sh2 "$@" ;;
        build-sh2-windows) step_build_sh2_windows "$@" ;;
        build-sgdk)      step_build_sgdk "$@" ;;
        build-dc)        step_build_dc "$@" ;;
        package)         step_package ;;
        package-windows) step_package_windows ;;
        clean)           step_clean ;;
        *)               die "usage: scripts/build_toolchain.sh fetch [--record | --record-missing] | build-gcc | build-sh2 | build-sh2-windows | build-sgdk | build-dc | package | package-windows | clean" ;;
    esac
}

main "$@"
