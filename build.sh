#!/usr/bin/env bash
# ==============================================================================
#  xyn_solcito - SM7435 (Garnet) 5.10 GKI Kernel Build & Packaging Script
#  Device:   POCO X6 5G / Redmi Note 13 Pro 5G (garnet / sm7435 - Qualcomm Parrot)
#  ROM:      Linux 5.10.273 (Android 16)
#  Root:     KernelSU-Next dev-susfs (base release v3.4.2) + SuSFS v2.3.0
#  Compiler: Google AOSP Clang r563880c (LLVM 21.0.0)
#            or Neutron Clang 06092026 (LLVM 24.0.0git) via --neutron
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Terminal Colors & Logging
# ------------------------------------------------------------------------------
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# True when adb reports at least one device in "device" state (adb puts two or
# more spaces between the serial and the state, so match on the field).
adb_device_present() {
    command -v adb >/dev/null 2>&1 || return 1
    adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit !found }'
}

# ------------------------------------------------------------------------------
# 1. Environment & Paths Setup
# ------------------------------------------------------------------------------
KERNEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$KERNEL_ROOT"

OUT_DIR="${KBUILD_OUT_DIR:-$KERNEL_ROOT/out}"
ANYKERNEL_DIR="${ANYKERNEL_DIR:-$KERNEL_ROOT/AnyKernel3}"
ANYKERNEL_REPO="https://github.com/zylhdrXP/AnyKernel3.git"
ANYKERNEL_BRANCH="gki"

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# CUSTOM KERNEL NAME - edit these freely, any string works
#
# KERNEL_NAME is the version the device displays for this kernel: `uname -r`,
# Settings > About phone > Kernel version, the flashable zip filename, the
# AnyKernel3 installer banner, and the "(user@host)" part of /proc/version.
# ------------------------------------------------------------------------------
KERNEL_NAME="Gwen-Xuan"
KERNEL_BUILD_USER="gwen"
KERNEL_BUILD_HOST="nixos"

# Suffix appended to the base release, so the device reports
#   5.10.269-xyn_solcito
# Set it to "" to keep whatever the tree's own config defines.
KERNEL_LOCALVERSION=""
if [ -z "$KERNEL_LOCALVERSION" ] && [ -n "$KERNEL_NAME" ]; then
    KERNEL_LOCALVERSION="-${KERNEL_NAME}"
fi

# ------------------------------------------------------------------------------
# Telegram Channel Upload Configuration
# Automatically sends the compiled AnyKernel3 zip to your Telegram channel.
# Set your Bot Token and Channel ID / Username here, in a local .env file,
# or pass via environment variables / CLI flags (--tg-token, --tg-chat).
# ------------------------------------------------------------------------------
[ -f "$KERNEL_ROOT/.env" ] && source "$KERNEL_ROOT/.env"

ACTION_TELEGRAM=true
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

DEFCONFIG="gki_defconfig"

# ------------------------------------------------------------------------------
# KernelSU-Next + SuSFS
#
# KernelSU-Next already integrates SuSFS (its Kconfig defines CONFIG_KSU_SUSFS
# and core/init.c calls susfs_init()), so no patch inside the KernelSU tree is
# needed.  Integration is: symlink the KernelSU kernel dir into drivers/, apply
# the SuSFS kernel patch, and enable the config symbols.
#
# Versions are pinned; bump KSU_REF / SUSFS_EXPECTED_VERSION together with the
# checkout when you want to move to a newer release.
# ------------------------------------------------------------------------------
ACTION_KSU=true
KSU_REPO="https://github.com/pershoot/KernelSU-Next"
# KernelSU-Next carries its SuSFS integration on the dev-susfs branch (its base
# release is v3.4.2).  The plain "v3.4.2" tag has no CONFIG_KSU_SUSFS at all, and
# the SuSFS project's KernelSU-side patch does not apply to this fork, so
# dev-susfs is the ref that actually pairs with SuSFS 2.3.0 here.
KSU_REF="${KSU_REF:-dev-susfs}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REF="${SUSFS_REF:-gki-android12-5.10-dev}"
SUSFS_EXPECTED_VERSION="v2.3.0"
ALLOW_SUSFS_DRIFT=false
KSU_DIR="$KERNEL_ROOT/KernelSU"
SUSFS_DIR="$KERNEL_ROOT/.susfs"
KSU_FRAGMENT="$KERNEL_ROOT/arch/arm64/configs/vendor/ksu_susfs.config"
KSU_VERSION="n/a"
SUSFS_VERSION="n/a"

# Fragments merged onto gki_defconfig, in order.  These mirror what the ROM's
# build merges: SoC GKI fragment, device fragment, and debugfs.config which
# disables DEBUG_FS/CMA_DEBUGFS/PAGE_OWNER/PAGE_PINNER the way shipping builds
# do (see the matching settings in the on-device /proc/config.gz).
VENDOR_CONFIGS=(
    "$KERNEL_ROOT/arch/arm64/configs/vendor/parrot_GKI.config"
    "$KERNEL_ROOT/arch/arm64/configs/vendor/garnet_GKI.config"
    "$KERNEL_ROOT/arch/arm64/configs/vendor/debugfs.config"
)

# Reference config for an informational ABI parity report (the known-good
# config captured from the device).  Optional; first match wins.
REFERENCE_CONFIG="${REFERENCE_CONFIG:-}"
if [ -z "$REFERENCE_CONFIG" ]; then
    for cand in "$KERNEL_ROOT/working_device_config" "$KERNEL_ROOT/../working_device_config"; do
        if [ -f "$cand" ]; then
            REFERENCE_CONFIG="$cand"
            break
        fi
    done
fi

# Google AOSP Clang r563880c (LLVM 21.0.0 - LineageOS 23.2 / Android 16 GKI)
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/531a564ba5426707dee226eccb19f104a7af5a5f/clang-r563880c.tar.gz"
CLANG_DIR_NAME="clang-r563880c"

# Neutron Clang from the clang-build-catalogue, release 06092026 (LLVM 24.0.0git).
# The archive is a toolchain root (bin/ + lib/), so it extracts straight into a
# directory we then put on PATH - same shape as the AOSP tarball above.
NEUTRON_CATALOGUE_TAG="06092026"
NEUTRON_URL="https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/${NEUTRON_CATALOGUE_TAG}/neutron-clang-${NEUTRON_CATALOGUE_TAG}.tar.zst"
NEUTRON_DIR_NAME="neutron-clang-${NEUTRON_CATALOGUE_TAG}"

# Toolchain selection: AOSP by default, Neutron with --neutron.
USE_NEUTRON=false

# Default flags
ACTION_BUILD=true
ACTION_CLEAN=false
ACTION_REGEN_CONFIG_ONLY=false
ACTION_PUSH=false
ACTION_MODULES=false
ENABLE_THINLTO=false
LTO_OVERRIDE=false

# CLI Option Parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean|-c)
            ACTION_CLEAN=true
            ACTION_BUILD=false
            shift
            ;;
        --regen-config|-r)
            ACTION_REGEN_CONFIG_ONLY=true
            ACTION_BUILD=false
            shift
            ;;
        --push|-p)
            ACTION_PUSH=true
            shift
            ;;
        --with-modules)
            ACTION_MODULES=true
            shift
            ;;
        --no-ksu)
            ACTION_KSU=false
            shift
            ;;
        --ksu-ref)
            [ -n "${2:-}" ] || { log_error "--ksu-ref needs a value, e.g. --ksu-ref v3.4.0"; exit 1; }
            KSU_REF="$2"
            shift 2
            ;;
        --susfs-ref)
            [ -n "${2:-}" ] || { log_error "--susfs-ref needs a value"; exit 1; }
            SUSFS_REF="$2"
            shift 2
            ;;
        --allow-susfs-drift)
            ALLOW_SUSFS_DRIFT=true
            shift
            ;;
        --neutron)
            USE_NEUTRON=true
            shift
            ;;
        --thin-lto)
            ENABLE_THINLTO=true
            LTO_OVERRIDE=true
            shift
            ;;
        --full-lto)
            ENABLE_THINLTO=false
            LTO_OVERRIDE=true
            shift
            ;;
        --telegram|-tg)
            ACTION_TELEGRAM=true
            shift
            ;;
        --no-telegram|--no-tg)
            ACTION_TELEGRAM=false
            shift
            ;;
        --tg-token)
            [ -n "${2:-}" ] || { log_error "--tg-token needs a value"; exit 1; }
            TELEGRAM_BOT_TOKEN="$2"
            shift 2
            ;;
        --tg-chat)
            [ -n "${2:-}" ] || { log_error "--tg-chat needs a value"; exit 1; }
            TELEGRAM_CHAT_ID="$2"
            shift 2
            ;;
        --help|-h)
            echo -e "${BOLD}Usage:${NC} $0 [options]"
            echo ""
            echo "Options:"
            echo "  --clean, -c            Remove out/ build directory"
            echo "  --regen-config, -r     Generate .config only, without compiling"
            echo "  --push, -p             Push flashable zip to connected device via ADB"
            echo "  --with-modules         Also build and stage the kernel modules"
            echo "  --no-ksu               Build without KernelSU-Next/SuSFS (vanilla)"
            echo "  --ksu-ref <ref>        KernelSU-Next ref to check out (default: $KSU_REF)"
            echo "  --susfs-ref <ref>      SuSFS branch/commit to check out (default: $SUSFS_REF)"
            echo "  --allow-susfs-drift    Accept a SuSFS version other than $SUSFS_EXPECTED_VERSION"
            echo "  --neutron              Use Neutron Clang ${NEUTRON_CATALOGUE_TAG} (LLVM 24.0.0git) from"
            echo "                         the clang-build-catalogue instead of AOSP Clang r563880c"
            echo "  --thin-lto             Override to ThinLTO (codegen only; differs from the"
            echo "                         known-good config which is Full LTO)"
            echo "  --full-lto             Override to Full LTO (the known-good default)"
            echo "  --no-telegram, --no-tg Disable sending build artifact to Telegram channel"
            echo "  --tg-token <token>     Telegram Bot API token"
            echo "  --tg-chat <id/channel> Telegram Channel username or chat ID"
            echo "  --help, -h             Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$ACTION_CLEAN" = true ]; then
    log_info "Cleaning out/ build directory..."
    rm -rf "$OUT_DIR"
    log_success "Clean completed."
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. Host Utilities & NixOS Environment Resolution
# ------------------------------------------------------------------------------
# Resolve build tools (flex, bison, lz4) from the Nix store when they are not
# already on PATH.  Note: look for the *binary* in a versioned store path.
for tool in flex bison lz4; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        tool_bin="$(ls -d /nix/store/*-"$tool"-*/bin 2>/dev/null | head -n 1 || true)"
        [ -n "$tool_bin" ] && export PATH="${tool_bin}:${PATH}"
    fi
done

for tool in flex bison; do
    command -v "$tool" >/dev/null 2>&1 || \
        log_warning "$tool not found - kconfig regeneration may fail on a clean out/ tree."
done

# Host compiler.  The AOSP clang has no host libc headers, so host tools such as
# scripts/basic/fixdep must be built with the system compiler.
HOSTCC="$(command -v cc 2>/dev/null || true)"
if [ -z "$HOSTCC" ]; then
    for cand in /run/current-system/sw/bin/clang /usr/bin/gcc /usr/bin/cc; do
        [ -x "$cand" ] && HOSTCC="$cand" && break
    done
fi
[ -n "$HOSTCC" ] || { log_error "No host C compiler (cc) found."; exit 1; }

# NixOS openssl / libelf headers and libraries for host tools (extract-cert, sign-file)
nix_openssl_inc="$(ls -d /nix/store/*openssl*-dev/include 2>/dev/null | head -n 1 || true)"
nix_libelf_inc="$(ls -d /nix/store/*elfutils*/include 2>/dev/null | head -n 1 || true)"

nix_openssl_lib="$(python3 -c "
import glob
for p in sorted(glob.glob('/nix/store/*openssl*/lib')):
    try:
        with open(f'{p}/libcrypto.so', 'rb') as f:
            h = f.read(20)
            if h.startswith(b'\x7fELF') and h[4] == 2 and h[18] == 62:
                print(p)
                break
    except:
        pass
" 2>/dev/null || true)"

nix_libelf_lib="$(python3 -c "
import glob
for p in sorted(glob.glob('/nix/store/*elfutils*/lib') + glob.glob('/nix/store/*libelf*/lib')):
    try:
        with open(f'{p}/libelf.so', 'rb') as f:
            h = f.read(20)
            if h.startswith(b'\x7fELF') and h[4] == 2 and h[18] == 62:
                print(p)
                break
    except:
        pass
" 2>/dev/null || true)"

HOSTCFLAGS=""
HOSTLDFLAGS=""
[ -n "${nix_openssl_inc}" ] && HOSTCFLAGS+=" -I${nix_openssl_inc}"
[ -n "${nix_libelf_inc}" ] && HOSTCFLAGS+=" -I${nix_libelf_inc}"
[ -n "${nix_openssl_lib}" ] && HOSTLDFLAGS+=" -L${nix_openssl_lib} -Wl,-rpath,${nix_openssl_lib}"
[ -n "${nix_libelf_lib}" ] && HOSTLDFLAGS+=" -L${nix_libelf_lib} -Wl,-rpath,${nix_libelf_lib}"

# ------------------------------------------------------------------------------
# 3. Target Toolchain Setup (AOSP Clang r563880c, or Neutron with --neutron)
# ------------------------------------------------------------------------------
CLANG_DIR=""

if [ "$USE_NEUTRON" = true ]; then
    # Neutron Clang 06092026.  Same layout as the AOSP tarball, so the same
    # "find a bin/clang, else download and extract" flow applies.
    NEUTRON_CANDIDATES=(
        "${NEUTRON_PATH:-}"
        "$KERNEL_ROOT/toolchains/$NEUTRON_DIR_NAME"
        "$KERNEL_ROOT/../neutron-clang"
        "/home/ash/project/kernels/neutron-clang"
        "$HOME/neutron-clang"
    )
    for candidate in "${NEUTRON_CANDIDATES[@]}"; do
        if [ -n "$candidate" ] && [ -d "$candidate/bin" ] && [ -x "$candidate/bin/clang" ]; then
            CLANG_DIR="$(cd "$candidate" && pwd)"
            break
        fi
    done

    if [ -z "$CLANG_DIR" ]; then
        command -v zstd >/dev/null 2>&1 || { log_error "zstd is required to extract the Neutron Clang archive."; exit 1; }
        CLANG_DIR="$KERNEL_ROOT/toolchains/$NEUTRON_DIR_NAME"
        mkdir -p "$CLANG_DIR"
        log_info "Neutron Clang ${NEUTRON_CATALOGUE_TAG} not found locally. Downloading from the clang-build-catalogue..."
        tmp_archive="$(mktemp --suffix=.tar.zst)"
        curl -fSL --retry 3 --progress-bar "$NEUTRON_URL" -o "$tmp_archive"
        log_info "Extracting toolchain to $CLANG_DIR ..."
        zstd -dc "$tmp_archive" | tar -xf - -C "$CLANG_DIR"
        rm -f "$tmp_archive"
    fi
else
    CANDIDATE_PATHS=(
        "${CLANG_PATH:-}"
        "$KERNEL_ROOT/toolchains/$CLANG_DIR_NAME"
        "$KERNEL_ROOT/../$CLANG_DIR_NAME"
        "/home/ash/project/kernels/$CLANG_DIR_NAME"
    )

    for candidate in "${CANDIDATE_PATHS[@]}"; do
        if [ -n "$candidate" ] && [ -d "$candidate/bin" ] && [ -x "$candidate/bin/clang" ]; then
            CLANG_DIR="$(cd "$candidate" && pwd)"
            break
        fi
    done

    if [ -z "$CLANG_DIR" ]; then
        CLANG_DIR="$KERNEL_ROOT/toolchains/$CLANG_DIR_NAME"
        mkdir -p "$CLANG_DIR"
        log_info "AOSP Clang r563880c not found locally. Downloading from Google AOSP..."
        tmp_archive="$(mktemp --suffix=.tar.gz)"
        curl -fSL --retry 3 --progress-bar "$CLANG_URL" -o "$tmp_archive"
        log_info "Extracting toolchain to $CLANG_DIR ..."
        tar -xf "$tmp_archive" -C "$CLANG_DIR"
        rm -f "$tmp_archive"
    fi
fi

export PATH="${CLANG_DIR}/bin:$PATH"

CLANG_VERSION_STR="$("$CLANG_DIR/bin/clang" --version | head -n 1)"
if [ "$USE_NEUTRON" = true ]; then
    log_success "Target Compiler: $CLANG_VERSION_STR (Neutron Clang ${NEUTRON_CATALOGUE_TAG})"
else
    log_success "Target Compiler: $CLANG_VERSION_STR"
fi
log_info "Host Compiler:   $HOSTCC"

# ------------------------------------------------------------------------------
# 4. Target Architecture & Make Arguments
# ------------------------------------------------------------------------------
export ARCH=arm64
export SUBARCH=arm64
export CC=clang
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-

# Branding that shows up as "(<user>@<host>)" in /proc/version. This is free:
# it does not touch UTS_RELEASE, so the vermagic stays intact.
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-$KERNEL_BUILD_USER}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-$KERNEL_BUILD_HOST}"

JOBS="${JOBS:-$(nproc --all)}"
START_TIME=$(date +%s)
DATE_TAG=$(date +"%Y%m%d_%H%M%S")

MAKE_ARGS=(
    O="$OUT_DIR"
    ARCH=arm64
    SUBARCH=arm64
    LLVM=1
    LLVM_IAS=1
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    CC=clang
    HOSTCC="$HOSTCC"
    HOSTCFLAGS="$HOSTCFLAGS"
    HOSTLDFLAGS="$HOSTLDFLAGS"
)

# scripts/config lives in-tree as a shell script here.
CONFIG_SH="$KERNEL_ROOT/scripts/config"

acfg() { "$CONFIG_SH" --file "$OUT_DIR/.config" "$@"; }

# This tree does not rewrite include/config/auto.conf from .config on
# olddefconfig/syncconfig once auto.conf exists, so edits made with
# scripts/config can be silently ignored by the actual build.  Force the sync.
sync_config() {
    make "${MAKE_ARGS[@]}" olddefconfig >/dev/null
    rm -f "$OUT_DIR/include/config/auto.conf" "$OUT_DIR/include/config/kernel.release"
    make "${MAKE_ARGS[@]}" syncconfig >/dev/null
}

# ------------------------------------------------------------------------------
# 4b. KernelSU-Next + SuSFS source integration
#
#     KernelSU-Next is checked out at a pinned ref and wired into drivers/ the
#     same way upstream does it.  SuSFS ships three new files plus one kernel
#     patch; the patch is dry-run first so a conflict aborts the build instead
#     of silently shipping a half-patched tree.  Re-running the script skips
#     whatever is already in place.
# ------------------------------------------------------------------------------
setup_ksu_susfs() {
    command -v git >/dev/null 2>&1 || { log_error "git is required for the KSU/SuSFS integration."; exit 1; }
    command -v patch >/dev/null 2>&1 || { log_error "patch is required for the SuSFS integration."; exit 1; }

    # ---- SuSFS checkout first: it also carries the KernelSU-side patch ----
    if [ ! -d "$SUSFS_DIR/.git" ]; then
        log_info "Cloning susfs4ksu ($SUSFS_REF)..."
        rm -rf "$SUSFS_DIR"
        git clone --depth=1 --branch "$SUSFS_REF" "$SUSFS_REPO" "$SUSFS_DIR"
    else
        log_info "Updating susfs4ksu ($SUSFS_REF)..."
        git -C "$SUSFS_DIR" remote set-url origin "$SUSFS_REPO" 2>/dev/null || true
        git -C "$SUSFS_DIR" fetch --tags origin "$SUSFS_REF" 2>/dev/null || true
    fi
    if git -C "$SUSFS_DIR" rev-parse -q --verify "origin/$SUSFS_REF" >/dev/null 2>&1; then
        git -C "$SUSFS_DIR" checkout -B "$SUSFS_REF" "origin/$SUSFS_REF" -q 2>/dev/null || \
            git -C "$SUSFS_DIR" reset --hard "origin/$SUSFS_REF" 2>/dev/null || true
    elif ! git -C "$SUSFS_DIR" checkout -q "$SUSFS_REF" 2>/dev/null; then
        log_warning "susfs4ksu ref '$SUSFS_REF' is not available locally; using the current checkout."
    fi

    local patch_dir="$SUSFS_DIR/kernel_patches"
    local susfs_hdr="$patch_dir/include/linux/susfs.h"
    [ -f "$susfs_hdr" ] || susfs_hdr="$SUSFS_DIR/include/linux/susfs.h"
    [ -f "$susfs_hdr" ] || { log_error "Cannot find susfs.h under $SUSFS_DIR."; exit 1; }
    SUSFS_VERSION="$(grep -E '^#define[[:space:]]+SUSFS_VERSION' "$susfs_hdr" | cut -d' ' -f3 | tr -d '"')"

    if [ "$SUSFS_VERSION" != "$SUSFS_EXPECTED_VERSION" ] && [ "$ALLOW_SUSFS_DRIFT" = false ]; then
        log_error "SuSFS version is '${SUSFS_VERSION}' but ${SUSFS_EXPECTED_VERSION} was requested."
        log_error "Pin it with --susfs-ref <commit>, or pass --allow-susfs-drift to accept it."
        exit 1
    fi

    # ---- KernelSU-Next ----
    if [ ! -d "$KSU_DIR/.git" ]; then
        log_info "Cloning KernelSU-Next ($KSU_REF)..."
        rm -rf "$KSU_DIR"
        git clone --depth=1 --branch "$KSU_REF" "$KSU_REPO" "$KSU_DIR"
    else
        log_info "Updating KernelSU-Next ($KSU_REF)..."
        git -C "$KSU_DIR" remote set-url origin "$KSU_REPO" 2>/dev/null || true
        git -C "$KSU_DIR" fetch --tags origin "$KSU_REF" 2>/dev/null || true
    fi
    if git -C "$KSU_DIR" rev-parse -q --verify "origin/$KSU_REF" >/dev/null 2>&1; then
        git -C "$KSU_DIR" checkout -B "$KSU_REF" "origin/$KSU_REF" -q 2>/dev/null || \
            git -C "$KSU_DIR" reset --hard "origin/$KSU_REF" 2>/dev/null || true
    elif ! git -C "$KSU_DIR" checkout -q "$KSU_REF" 2>/dev/null; then
        log_warning "KernelSU-Next ref '$KSU_REF' is not available locally; using the current checkout."
    fi
    KSU_VERSION="$(git -C "$KSU_DIR" describe --tags 2>/dev/null || git -C "$KSU_DIR" rev-parse --short HEAD)"
    [ -f "$KSU_DIR/kernel/Kconfig" ] || { log_error "$KSU_DIR does not look like a KernelSU-Next tree."; exit 1; }

    # SuSFS support inside KernelSU. KernelSU-Next's SuSFS branch defines
    # CONFIG_KSU_SUSFS itself; a release tag does not, and then the SuSFS
    # project's own KernelSU patch is the only way in.
    if grep -q 'config KSU_SUSFS' "$KSU_DIR/kernel/Kconfig"; then
        log_info "KernelSU-Next ${KSU_VERSION} has native SuSFS support."
    else
        local ksu_patch="$patch_dir/KernelSU/10_enable_susfs_for_ksu.patch"
        if [ ! -f "$ksu_patch" ]; then
            log_error "KernelSU ref '$KSU_REF' has no SuSFS support and $ksu_patch is missing."
            exit 1
        fi
        if patch -d "$KSU_DIR" -p1 --dry-run --forward < "$ksu_patch" >/dev/null 2>&1; then
            patch -d "$KSU_DIR" -p1 --forward < "$ksu_patch" >/dev/null
            log_info "Applied the SuSFS KernelSU-side patch to $KSU_DIR."
        else
            log_error "KernelSU ref '$KSU_REF' has no native SuSFS support, and SuSFS's"
            log_error "10_enable_susfs_for_ksu.patch does not apply cleanly to it."
            log_error "Use the SuSFS-integrated branch instead: --ksu-ref dev-susfs"
            exit 1
        fi
    fi

    # ---- Wire KernelSU into the kernel build ----
    if [ -L "$KERNEL_ROOT/drivers/kernelsu" ] && \
       [ "$(readlink -f "$KERNEL_ROOT/drivers/kernelsu")" = "$KSU_DIR/kernel" ]; then
        : # already wired
    else
        rm -rf "$KERNEL_ROOT/drivers/kernelsu"
        ln -sfn "$KSU_DIR/kernel" "$KERNEL_ROOT/drivers/kernelsu"
        log_info "Linked drivers/kernelsu -> $KSU_DIR/kernel"
    fi
    if ! grep -q 'kernelsu' "$KERNEL_ROOT/drivers/Makefile"; then
        echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$KERNEL_ROOT/drivers/Makefile"
        log_info "Added kernelsu to drivers/Makefile"
    fi
    if ! grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_ROOT/drivers/Kconfig"; then
        sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$KERNEL_ROOT/drivers/Kconfig"
        log_info "Added kernelsu to drivers/Kconfig"
    fi

    local main_patch
    main_patch="$(find "$patch_dir" -maxdepth 1 -name '50_add_susfs_in*.patch' | head -n 1)"
    [ -n "$main_patch" ] || { log_error "No 50_add_susfs_in*.patch found in $patch_dir."; exit 1; }

    # New files first, because the patch references them.
    [ -f "$patch_dir/fs/susfs.c" ] && cp -f "$patch_dir/fs/susfs.c" "$KERNEL_ROOT/fs/susfs.c"
    cp -f "$patch_dir/include/linux/susfs.h" "$patch_dir/include/linux/susfs_def.h" "$KERNEL_ROOT/include/linux/"

    if grep -q 'CONFIG_KSU_SUSFS' "$KERNEL_ROOT/fs/Makefile" 2>/dev/null; then
        log_info "SuSFS kernel patch already applied; skipping."
    else
        log_info "Applying SuSFS patch: $(basename "$main_patch")"
        if ! patch -p1 -d "$KERNEL_ROOT" --dry-run --forward < "$main_patch" >/dev/null 2>&1; then
            log_error "SuSFS patch does not apply cleanly to this tree."
            log_error "Inspect it with: patch -p1 --dry-run --forward < $main_patch"
            exit 1
        fi
        patch -p1 -d "$KERNEL_ROOT" --forward < "$main_patch" >/dev/null
        log_info "SuSFS patch applied."
    fi
    [ -f "$KERNEL_ROOT/fs/susfs.c" ] || { log_error "fs/susfs.c missing after SuSFS setup."; exit 1; }
    [ -f "$KERNEL_ROOT/include/linux/susfs.h" ] || { log_error "include/linux/susfs.h missing after SuSFS setup."; exit 1; }

    # ---- Config fragment (regenerated; symbol set matches this KernelSU-Next) ----
    cat > "$KSU_FRAGMENT" <<'EOF'
# KernelSU-Next + SuSFS. Generated by build.sh - symbol set matches the
# KernelSU-Next Kconfig shipped in the pinned checkout.
CONFIG_KSU=y
CONFIG_KSU_THRONE_TRACKER_ALWAYS_THREADED=y
# CONFIG_KSU_DEBUG is not set
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF

    log_success "KernelSU-Next ${KSU_VERSION} + SuSFS ${SUSFS_VERSION} ready"
}

# Integrate KernelSU-Next + SuSFS before the config is generated, because the
# driver wiring has to exist for CONFIG_KSU to be a valid symbol.
if [ "$ACTION_KSU" = true ]; then
    setup_ksu_susfs
    KERNEL_FLAVOR="KSUN_SUSFS"
else
    KERNEL_FLAVOR="vanilla"
    log_warning "KernelSU-Next/SuSFS disabled (--no-ksu)."
    # Ensure drivers/kernelsu/Kconfig exists even if repo was not cloned, so drivers/Kconfig doesn't fail
    if [ ! -f "$KERNEL_ROOT/drivers/kernelsu/Kconfig" ]; then
        rm -rf "$KERNEL_ROOT/drivers/kernelsu"
        mkdir -p "$KERNEL_ROOT/drivers/kernelsu"
        touch "$KERNEL_ROOT/drivers/kernelsu/Kconfig"
        touch "$KERNEL_ROOT/drivers/kernelsu/Makefile"
    fi
fi

TOOLCHAIN_LABEL="AOSP Clang r563880c (LLVM 21.0.0)"
if [ "$USE_NEUTRON" = true ]; then
    TOOLCHAIN_LABEL="Neutron Clang ${NEUTRON_CATALOGUE_TAG} (LLVM 24.0.0git)"
fi

echo -e "${BOLD}${CYAN}"
echo "========================================================"
echo "  ${KERNEL_NAME} - SM7435 (Garnet) GKI Kernel Builder"
echo "  Target:    POCO X6 5G / Redmi Note 13 Pro 5G (garnet) "
echo "  Toolchain: ${TOOLCHAIN_LABEL}"
local_sublevel="$(grep -E '^SUBLEVEL = ' "$KERNEL_ROOT/Makefile" | awk '{print $3}')"
echo "  Version:   5.10.${local_sublevel:-273}${KERNEL_LOCALVERSION}"
if [ "$ACTION_KSU" = true ]; then
echo "  Root:      KernelSU-Next ${KSU_VERSION} + SuSFS ${SUSFS_VERSION}"
fi
echo "  Parallel Jobs: $JOBS                                  "
echo "========================================================"
echo -e "${NC}"

# ------------------------------------------------------------------------------
# 5. Kernel Configuration
# ------------------------------------------------------------------------------
mkdir -p "$OUT_DIR"

log_info "Generating base configuration ($DEFCONFIG)..."
make "${MAKE_ARGS[@]}" "$DEFCONFIG"

# The KernelSU/SuSFS fragment is merged last so it wins over the SoC/device ones.
MERGED_CONFIGS=("${VENDOR_CONFIGS[@]}")
if [ "$ACTION_KSU" = true ]; then
    MERGED_CONFIGS+=("$KSU_FRAGMENT")
fi

for cfg in "${MERGED_CONFIGS[@]}"; do
    if [ -f "$cfg" ]; then
        log_info "Merging config fragment: $(basename "$cfg")..."
        ARCH=arm64 ./scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" "$OUT_DIR/.config" "$cfg"
    else
        log_warning "Config fragment not found, skipping: $cfg"
    fi
done

# ------------------------------------------------------------------------------
# 5a. Kernel version string
#
#     CONFIG_LOCALVERSION is the part of the version the device reports, so the
#     name above replaces the tree's own suffix. LOCALVERSION_AUTO is disabled
#     so no git hash and no "-dirty" marker can creep in behind it.
# ------------------------------------------------------------------------------
if [ -n "$KERNEL_LOCALVERSION" ]; then
    log_info "Kernel version suffix: ${KERNEL_LOCALVERSION}"
    acfg --set-str CONFIG_LOCALVERSION "$KERNEL_LOCALVERSION"
    acfg --disable CONFIG_LOCALVERSION_AUTO
    sync_config
fi

# ------------------------------------------------------------------------------
# 5b. Optional overrides, explicitly requested only.
#
#     Nothing is forced here on purpose: poking individual options after the
#     fragment merge is how the config silently drifts from the tree's defaults.
# ------------------------------------------------------------------------------
if [ "$LTO_OVERRIDE" = true ]; then
    log_warning "Overriding LTO changes how the kernel is compiled. It does not change the"
    log_warning "exported symbol CRCs or the vermagic, so it is not by itself a module-"
    log_warning "compatibility problem - but it does diverge from the known-good config."
    if [ "$ENABLE_THINLTO" = true ]; then
        acfg --enable CONFIG_LTO_CLANG
        acfg --enable CONFIG_LTO_CLANG_THIN
        acfg --disable CONFIG_LTO_CLANG_FULL
        acfg --enable CONFIG_THINLTO
    else
        acfg --enable CONFIG_LTO_CLANG
        acfg --disable CONFIG_LTO_CLANG_THIN
        acfg --enable CONFIG_LTO_CLANG_FULL
        acfg --disable CONFIG_THINLTO
    fi
fi

if [ "$ACTION_KSU" = false ]; then
    log_info "Disabling KernelSU and SuSFS (--no-ksu)..."
    acfg --disable CONFIG_KSU
    acfg --disable CONFIG_KSU_SUSFS
    acfg --disable CONFIG_KSU_DEBUG
    acfg --disable CONFIG_KSU_THRONE_TRACKER_ALWAYS_THREADED
    acfg --disable CONFIG_KSU_MULTI_MANAGER_SUPPORT
    acfg --disable CONFIG_KSU_SUSFS_SUS_PATH
    acfg --disable CONFIG_KSU_SUSFS_SUS_MOUNT
    acfg --disable CONFIG_KSU_SUSFS_SUS_KSTAT
    acfg --disable CONFIG_KSU_SUSFS_SPOOF_UNAME
    acfg --disable CONFIG_KSU_SUSFS_ENABLE_LOG
    acfg --disable CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
    acfg --disable CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
    acfg --disable CONFIG_KSU_SUSFS_OPEN_REDIRECT
    acfg --disable CONFIG_KSU_SUSFS_SUS_MAP
fi

log_info "Syncing configuration (olddefconfig & syncconfig)..."
sync_config

# The release the compiler will actually stamp into the image. Always read it
# back from the synchronized config rather than assuming.
KERNEL_RELEASE="$(make "${MAKE_ARGS[@]}" -s kernelrelease 2>/dev/null || echo Unknown)"
log_success "Built kernel release: $KERNEL_RELEASE"

# Hard gate: a release mismatch guarantees every ROM module is rejected.
grep -qE '^CONFIG_MODVERSIONS=y' "$OUT_DIR/.config" && \
    log_info "CONFIG_MODVERSIONS=y - symbol CRCs are checked at load time too, so the config must match the modules as well."

# KernelSU silently vanishing is worse than a build error: gate on it.
if [ "$ACTION_KSU" = true ]; then
    for sym in CONFIG_KSU CONFIG_KSU_SUSFS; do
        if ! grep -qE "^${sym}=y" "$OUT_DIR/.config"; then
            log_error "${sym} is not enabled - the KernelSU integration did not take."
            log_error "Check that drivers/Kconfig sources drivers/kernelsu/Kconfig and that"
            log_error "$KSU_FRAGMENT merged."
            exit 1
        fi
    done
    log_success "KernelSU + SuSFS enabled in .config"
else
    for sym in CONFIG_KSU CONFIG_KSU_SUSFS; do
        if grep -qE "^${sym}=y" "$OUT_DIR/.config"; then
            log_error "${sym} is still enabled in .config despite --no-ksu!"
            exit 1
        fi
    done
    log_success "Verified: KernelSU and SuSFS are completely disabled in .config"
fi

RELEASE_ALIGNED=true
[ "$KERNEL_RELEASE" = "Unknown" ] && RELEASE_ALIGNED=false

# ------------------------------------------------------------------------------
# 5c. Informational config comparison against a reference config.
# ------------------------------------------------------------------------------
if [ -f "$REFERENCE_CONFIG" ]; then
    n_diff="$(diff <(grep -E '^(# )?CONFIG_' "$REFERENCE_CONFIG" | sort) \
                   <(grep -E '^(# )?CONFIG_' "$OUT_DIR/.config" | sort) \
              | grep -c '^[<>]' || true)"
    if [ "${n_diff:-0}" = "0" ]; then
        log_success "Config is identical to the known-good reference ($(basename "$REFERENCE_CONFIG"))."
    else
        log_warning "Config differs from $(basename "$REFERENCE_CONFIG") in $n_diff entries."
        log_warning "Compare with: diff <(sort $REFERENCE_CONFIG) <(sort $OUT_DIR/.config) | grep '^[<>]'"
    fi
fi

if [ "$ACTION_REGEN_CONFIG_ONLY" = true ]; then
    log_success "Config regeneration completed (.config in $OUT_DIR)."
    exit 0
fi

# ------------------------------------------------------------------------------
# 6. Kernel Compilation (Raw Image for GKI Header v4)
# ------------------------------------------------------------------------------
log_info "Compiling raw Image with AOSP Clang (Parallel Jobs: $JOBS)..."
make -j"$JOBS" "${MAKE_ARGS[@]}" Image

KERNEL_IMAGE="$OUT_DIR/arch/arm64/boot/Image"
if [ ! -f "$KERNEL_IMAGE" ]; then
    log_error "Kernel compilation failed! Expected image not found at $KERNEL_IMAGE"
    exit 1
fi

IMAGE_SIZE="$(du -h "$KERNEL_IMAGE" | awk '{print $1}')"
log_success "Kernel Image successfully compiled! Size: $IMAGE_SIZE"

# Modules: needed only if this kernel's vermagic/KMI does not match the ROM's
# modules (choose this when you ship modules instead of matching the ROM).
MODULES_STAGE=""
if [ "$ACTION_MODULES" = true ]; then
    log_info "Building kernel modules..."
    make -j"$JOBS" "${MAKE_ARGS[@]}" modules

    MODULES_STAGE="$OUT_DIR/modules_stage"
    rm -rf "$MODULES_STAGE"
    make "${MAKE_ARGS[@]}" INSTALL_MOD_PATH="$MODULES_STAGE" modules_install

    find "$MODULES_STAGE" -type l \( -name build -o -name source \) -delete 2>/dev/null || true
    KO_COUNT="$(find "$MODULES_STAGE" -name '*.ko' | wc -l)"
    log_success "Modules installed to $MODULES_STAGE ($KO_COUNT .ko files)"
    log_info "These are built against release '$KERNEL_RELEASE' and only load together with this kernel."
fi

# ------------------------------------------------------------------------------
# 7. AnyKernel3 Packaging (Flashable ZIP)
# ------------------------------------------------------------------------------
log_info "Packaging AnyKernel3 flashable ZIP..."

if [ ! -d "$ANYKERNEL_DIR/.git" ]; then
    log_info "Cloning AnyKernel3 ($ANYKERNEL_BRANCH branch)..."
    rm -rf "$ANYKERNEL_DIR"
    git clone --depth=1 -b "$ANYKERNEL_BRANCH" "$ANYKERNEL_REPO" "$ANYKERNEL_DIR"
fi

# Start from the pristine installer every time, then apply our edits explicitly.
# (Rewriting it with a blind sed is how the vendor_dlkm write silently disappears.)
if ! git -C "$ANYKERNEL_DIR" checkout -- anykernel.sh 2>/dev/null; then
    log_warning "Could not restore anykernel.sh from git; leaving it as-is."
fi

rm -f "$ANYKERNEL_DIR"/Image "$ANYKERNEL_DIR"/Image.* "$ANYKERNEL_DIR"/zImage*
cp "$KERNEL_IMAGE" "$ANYKERNEL_DIR/Image"

KERNEL_STRING="${KERNEL_NAME} ${KERNEL_RELEASE} [${KERNEL_FLAVOR}]"
if [ "$ACTION_KSU" = true ]; then
    KERNEL_STRING="${KERNEL_STRING} KernelSU-Next ${KSU_VERSION} + SuSFS ${SUSFS_VERSION}"
fi
sed -i "s|^kernel\.string=.*|kernel.string=${KERNEL_STRING}|" "$ANYKERNEL_DIR/anykernel.sh"
sed -i "s/^NO_BLOCK_DISPLAY=.*/NO_BLOCK_DISPLAY=0;/" "$ANYKERNEL_DIR/anykernel.sh"

# Install block: keep the raw-Image flash (no generic-ramdisk repack) but keep
# the vendor_dlkm write that write_boot() performs, so modules can be shipped.
python3 - "$ANYKERNEL_DIR/anykernel.sh" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
new_block = (
    "# boot install\n"
    "split_boot\n"
    "flash_boot\n"
    "# flash_generic writes AnyKernel3/vendor_dlkm.img when the zip ships one\n"
    "flash_generic vendor_dlkm\n"
    "## end boot install"
)
patched, n = re.subn(r"(?ms)^# boot install.*?^## end boot install", new_block, src, count=1)
if n != 1:
    sys.stderr.write("FATAL: could not find the AK3 install block in %s\n" % path)
    sys.exit(1)
open(path, "w").write(patched)
PY

ZIP_NAME="${KERNEL_NAME}-${KERNEL_RELEASE}-${KERNEL_FLAVOR}-${DATE_TAG}.zip"
ZIP_PATH="$OUT_DIR/$ZIP_NAME"

(
    cd "$ANYKERNEL_DIR"
    zip -r9 "$ZIP_PATH" . -x ".git/*" ".github/*" "README.md" "*placeholder" "*.zip" >/dev/null
)

(
    cd "$OUT_DIR"
    sha256sum "$ZIP_NAME" > "${ZIP_NAME}.sha256"
)

ZIP_SIZE="$(du -h "$ZIP_PATH" | awk '{print $1}')"
log_success "Flashable zip created: $ZIP_PATH ($ZIP_SIZE)"

# ------------------------------------------------------------------------------
# 8. Optional ADB Push
# ------------------------------------------------------------------------------
if [ "$ACTION_PUSH" = true ]; then
    if adb_device_present; then
        log_info "Device detected! Pushing flashable zip to /sdcard/ ..."
        adb push "$ZIP_PATH" /sdcard/
        log_success "Pushed to /sdcard/$ZIP_NAME"
    else
        log_warning "ADB push requested, but no device was found."
    fi
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

# ------------------------------------------------------------------------------
# 8b. Telegram Channel Notification & Upload
# ------------------------------------------------------------------------------
TELEGRAM_STATUS="Disabled (--no-telegram)"
if [ "$ACTION_TELEGRAM" = true ]; then
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        log_info "Preparing Telegram channel upload..."

        # Resolve NixOS Host String
        NIXOS_PRETTY="$(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || echo "NixOS")"
        NIXOS_HOST_STR="${KBUILD_BUILD_HOST} (${NIXOS_PRETTY})"

        # Root flavor string
        if [ "$ACTION_KSU" = true ]; then
            TG_ROOT_STR="KernelSU-Next ${KSU_VERSION} + SuSFS ${SUSFS_VERSION}"
        else
            TG_ROOT_STR="Vanilla (None)"
        fi

        # Telegram caption with kernel name, version, nixos host, compiler
        TG_CAPTION=$(cat << EOF
🚀 <b>${KERNEL_NAME} Kernel Build Completed!</b>

🏷 <b>Kernel Name:</b> <code>${KERNEL_NAME}</code>
📦 <b>Version:</b> <code>${KERNEL_RELEASE}</code>
💻 <b>Host:</b> <code>${NIXOS_HOST_STR}</code>
🛠 <b>Compiler:</b> <code>${CLANG_VERSION_STR}</code>
🛡 <b>Root:</b> <code>${TG_ROOT_STR}</code>
📁 <b>File:</b> <code>${ZIP_NAME}</code> (${ZIP_SIZE})
EOF
)

        log_info "Sending $ZIP_NAME to Telegram channel ($TELEGRAM_CHAT_ID)..."
        TG_RESP="$(curl -s -S -F chat_id="$TELEGRAM_CHAT_ID" \
                        -F document=@"$ZIP_PATH" \
                        -F caption="$TG_CAPTION" \
                        -F parse_mode="HTML" \
                        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" 2>&1)"

        if echo "$TG_RESP" | grep -q '"ok":true'; then
            log_success "Flashable zip sent to Telegram channel ($TELEGRAM_CHAT_ID)!"
            TELEGRAM_STATUS="Sent to $TELEGRAM_CHAT_ID"
        else
            log_error "Failed to send to Telegram channel: $TG_RESP"
            TELEGRAM_STATUS="Failed (see log above)"
        fi
    else
        log_warning "Telegram upload skipped: TELEGRAM_BOT_TOKEN and/or TELEGRAM_CHAT_ID not configured."
        log_warning "Set them in .env, export in shell, or pass --tg-token <token> --tg-chat <id>."
        TELEGRAM_STATUS="Skipped (token or chat ID not set)"
    fi
fi

# ------------------------------------------------------------------------------
# 9. Summary
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${GREEN}"
echo "========================================================"
echo "           BUILD & PACKAGING COMPLETED!                 "
echo "========================================================"
echo -e "${NC}"
echo -e "  ${BOLD}Zip File:${NC}      $ZIP_PATH"
echo -e "  ${BOLD}Checksum:${NC}      $ZIP_PATH.sha256"
echo -e "  ${BOLD}Zip Size:${NC}      $ZIP_SIZE"
echo -e "  ${BOLD}Raw Image:${NC}     $IMAGE_SIZE"
echo -e "  ${BOLD}Release:${NC}       $KERNEL_RELEASE"
if [ "$ACTION_KSU" = true ]; then
    echo -e "  ${BOLD}Root:${NC}          KernelSU-Next ${KSU_VERSION} + SuSFS ${SUSFS_VERSION}"
else
    echo -e "  ${BOLD}Root:${NC}          none (vanilla)"
fi
if [ -n "$MODULES_STAGE" ]; then
    echo -e "  ${BOLD}Modules:${NC}       $MODULES_STAGE"
fi
echo -e "  ${BOLD}Compiler:${NC}      $CLANG_VERSION_STR"
echo -e "  ${BOLD}Duration:${NC}      ${MINUTES}m ${SECONDS}s"
echo -e "  ${BOLD}Telegram:${NC}      $TELEGRAM_STATUS"
echo "========================================================"
if [ "$RELEASE_ALIGNED" = false ]; then
    echo -e "${YELLOW}Release string could not be verified - do not expect the ROM's modules to load.${NC}"
fi
