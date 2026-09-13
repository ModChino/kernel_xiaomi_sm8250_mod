#!/bin/bash

# Some logics of this script are copied from [scripts/build_kernel]. Thanks to UtsavBalar1231.
#
# ---------------------------------------------------------------------------
# enuma (Xiaomi Pad 5 Pro 5G) - TWO KernelSU lines in ONE script
#
#   MIUI_ONLY=1 (default) build only the MIUI variant, the AOSP block is skipped
#   WITH_SUSFS=0 (default) clean line : SukiSU-Ultra/SukiSU-Ultra v4.2.0  (4.x)
#                          -> Kernel_MIUI_enuma_SukiSU_*_anykernel3_*.zip
#   WITH_SUSFS=1           SUSFS line : KernelSU carrying the SUSFS 1.5.x glue
#                          -> Kernel_MIUI_enuma_SukiSU-SUSFS_*_anykernel3_*.zip
#
# Usage:
#     MIUI_ONLY=1 WITH_SUSFS=0 bash build.sh enuma ksu
#     MIUI_ONLY=1 WITH_SUSFS=1 bash build.sh enuma ksu
#
# KernelSU sources - both pinned to immutable commits:
#   clean line : 85eb4a95b8a61d756ecf53b9c5785e48e1b15039 = tag v4.2.0
#   SUSFS line : f4863b20cc8dc0f8cc67418980f022e43014b598 = liyafe1997/SukiSU-Ultra "susfs-1.5.7"
#
# Why the SUSFS line does NOT patch ShirkNeko/susfs4ksu@kernel-4.19 (SUSFS 1.5.8)
# into the v4.2.0 KernelSU tree:
#   * this kernel tree ALREADY contains the SUSFS fs-side code
#     (fs/susfs.c + include/linux/susfs.h = "v1.5.7", fs/Makefile:
#      obj-$(CONFIG_KSU_SUSFS) += susfs.o), so there is nothing to patch in:
#     that release's 50_add_susfs_in_kernel-4.19.patch is the very fs-side patch
#     this tree already carries (at 1.5.7) and its fs/Makefile hunk would conflict;
#   * its 10_enable_susfs_for_ksu.patch is written against KernelSU 3.x
#     (baseline "sync with KernelSU tag v1.0.5"): 11 of its 18 target files
#     (core_hook.c, ksu.c, ksud.c, allowlist.c, apk_sign.c, sucompat.c, ...)
#     no longer exist in the 4.x tree and 3 hunks conflict -> it cannot be
#     applied to v4.2.0 at all;
#   * the SUSFS line therefore uses the KernelSU tree whose SUSFS side matches
#     the in-tree 1.5.7 code (liyafe1997's susfs-1.5.7 branch), which is also the
#     combination already verified on the device (ksud 3.2.0 + susfs4ksu
#     1.5.7-R28).
#   Consequence: metamodule / SukiSU 4.x userspace comes from the clean line.
#   The SUSFS line stays on the older KernelSU and must be used with a 3.2.x
#   SukiSU manager (upstream README: "SukiSU Manager 4.0 and above are not
#   supported yet of the SukiSU version in this kernel").
#
# Both lines share one kernel tree, therefore:
#   * the AOSP and the MIUI build block each apply the KernelSU configuration
#     block on their own (kept in sync by hand, as in the original script);
#   * scripts/config never validates symbol names (it only rewrites .config) and
#     `make olddefconfig` silently drops symbols that do not exist or whose
#     dependencies are unmet -> every config block is followed by an explicit
#     `make olddefconfig` plus hard gates, so a line can never be "green" while
#     the requested feature is actually missing from the kernel.
# ---------------------------------------------------------------------------

# Ensure the script exits on error
set -e

# Toolchain: default stays the documented proton-clang 20210522 path, but the
# variable is now overridable from the environment. The CI workflow passes the
# AOSP clang r487747c prebuilt (Android (10087095, ...based on r487747c) clang
# version 17.0.2), which is the compiler the last known-good released enuma
# package was built with - see .github/workflows/build.yml.
TOOLCHAIN_PATH=${TOOLCHAIN_PATH:-$HOME/proton-clang/proton-clang-20210522/bin}
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE=$1

# ---- build line switches ---------------------------------------------------
# MIUI_ONLY: 1 (default) = build the MIUI variant only, skip the AOSP block
# WITH_SUSFS: 0 (default) = clean SukiSU v4.2.0 line, 1 = SUSFS line
MIUI_ONLY=${MIUI_ONLY:-1}
WITH_SUSFS=${WITH_SUSFS:-0}

case "$MIUI_ONLY" in
    0|1) ;;
    *) echo "MIUI_ONLY must be 0 or 1 (got: [$MIUI_ONLY])"; exit 1 ;;
esac

case "$WITH_SUSFS" in
    0|1) ;;
    *) echo "WITH_SUSFS must be 0 or 1 (got: [$WITH_SUSFS])"; exit 1 ;;
esac

# ---- KernelSU sources (immutable commits) ----------------------------------
# clean line: SukiSU-Ultra/SukiSU-Ultra tag v4.2.0 (4.x, metamodule capable)
KSU_REF_CLEAN=85eb4a95b8a61d756ecf53b9c5785e48e1b15039
# SUSFS line: liyafe1997/SukiSU-Ultra branch susfs-1.5.7 (matches this tree's
# in-kernel SUSFS 1.5.7 fs-side code)
KSU_REF_SUSFS=f4863b20cc8dc0f8cc67418980f022e43014b598
# Official setup.sh of v4.2.0 (blob 7e57e19b8408c7542865af5076cbee28783b3c7c).
# It clones https://github.com/SukiSU-Ultra/SukiSU-Ultra (unless a KernelSU/
# directory already exists), wires it into drivers/ and checks out the ref given
# as its first argument. A commit sha is used because "git checkout v4.2.0" is
# not guaranteed to resolve in every clone setup.
KSU_SETUP_URL=https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/85eb4a95b8a61d756ecf53b9c5785e48e1b15039/kernel/setup.sh

if [ -z "$1" ]; then
    echo "Error: No argument provided, please specific a target device." 
    echo "If you need KernelSU, please add [ksu] as the second arg."
    echo "Examples:"
    echo "Build for lmi(K30 Pro/POCO F2 Pro) without KernelSU:"
    echo "    bash build.sh lmi"
    echo "Build for umi(Mi10) with KernelSU:"
    echo "    bash build.sh umi ksu"
    exit 1
fi



if [ ! -d $TOOLCHAIN_PATH ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    echo "Please ensure the toolchain is there, or change TOOLCHAIN_PATH in the script to your toolchain path."
    exit 1
fi

echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"

if ! command -v aarch64-linux-gnu-ld >/dev/null 2>&1; then
    echo "[aarch64-linux-gnu-ld] does not exist, please check your environment."
    exit 1
fi

if ! command -v arm-linux-gnueabi-ld >/dev/null 2>&1; then
    echo "[arm-linux-gnueabi-ld] does not exist, please check your environment."
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "[clang] does not exist, please check your environment."
    exit 1
fi


# Enable ccache for speed up compiling 
export CCACHE_DIR="$HOME/.cache/ccache_mikernel" 
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:$PATH"
echo "CCACHE_DIR: [$CCACHE_DIR]"


MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"


if [ "$1" == "j1" ]; then
    make $MAKE_ARGS -j1
    exit
fi

if [ "$1" == "continue" ]; then
    make $MAKE_ARGS -j$(nproc)
    exit
fi

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    echo "Avaliable defconfigs, please choose one target from below down:"
    ls arch/arm64/configs/*_defconfig
    exit 1
fi


# Check clang is existing.
echo "[clang --version]:"
clang --version



KSU_ZIP_STR=NoKernelSU
if [ "${2:-}" = "ksu" ]; then
    KSU_ENABLE=1
    if [ "$WITH_SUSFS" -eq 1 ]; then
        KSU_ZIP_STR=SukiSU-SUSFS
    else
        KSU_ZIP_STR=SukiSU
    fi
else
    KSU_ENABLE=0
fi


# ---- config gates ----------------------------------------------------------
# scripts/config does not check the validity of .config and `make olddefconfig`
# drops unknown / unsatisfied symbols silently. These helpers turn the resulting
# "green but feature-less" build into a hard failure.
require_config() {
    if ! grep -q "^CONFIG_$1=y" out/.config; then
        echo "FATAL: CONFIG_$1 is not enabled in out/.config."
        echo "       (symbol unknown or its dependencies are not met - the feature would be missing)"
        exit 1
    fi
}

forbid_config() {
    if grep -q "^CONFIG_$1=y" out/.config; then
        echo "FATAL: CONFIG_$1 must not be enabled in out/.config."
        exit 1
    fi
}

forbid_symbol() {
    if grep -q "CONFIG_$1" out/.config; then
        echo "FATAL: CONFIG_$1 must not appear in out/.config."
        echo "       (this symbol does not exist on the selected line)"
        exit 1
    fi
}


echo "TARGET_DEVICE: $TARGET_DEVICE"
echo "MIUI_ONLY: [$MIUI_ONLY] WITH_SUSFS: [$WITH_SUSFS] KSU: [$KSU_ZIP_STR]"

if [ $KSU_ENABLE -eq 1 ]; then
    echo "KSU is enabled"
    if [ "$WITH_SUSFS" -eq 1 ]; then
        KSU_REF=$KSU_REF_SUSFS
        # The official setup.sh can only clone the official repository, so the
        # fork tree is fetched here first at its pinned commit; setup.sh then
        # skips its own clone (test -d "$GKI_ROOT/KernelSU" || git clone ...)
        # and only performs the wiring + checkout.
        git clone https://github.com/liyafe1997/SukiSU-Ultra KernelSU
    else
        KSU_REF=$KSU_REF_CLEAN
    fi

    echo "KernelSU ref: [$KSU_REF]"
    echo "KernelSU setup: [$KSU_SETUP_URL]"
    curl -LSs "$KSU_SETUP_URL" | bash -s "$KSU_REF"

    # setup.sh swallows a failed `git checkout <ref>` (git checkout "$1" || echo
    # "Checkout default branch"), so verify the tree that will really be compiled.
    KSU_HEAD=$(git -C KernelSU rev-parse HEAD)
    if [ "$KSU_HEAD" != "$KSU_REF" ]; then
        echo "FATAL: KernelSU is at [$KSU_HEAD] but [$KSU_REF] was requested."
        exit 1
    fi
    if [ ! -e drivers/kernelsu/Kconfig ] && [ ! -e drivers/kernelsu/Kbuild ]; then
        echo "FATAL: drivers/kernelsu is not wired into the kernel tree."
        exit 1
    fi

    # t13/F1: the 4.x KernelSU tree needs the private security/selinux/ss include
    # directory. Its kernel/feature/selinux_hide.c includes <ss/context.h>,
    # <ss/services.h>, <ss/mls.h> and <ss/conditional.h>, and in this 4.19 kernel
    # those headers live in security/selinux/ss/ - neither of the two paths that
    # the tree already carries (security/selinux, security/selinux/include)
    # resolves them, so the A line would die with "fatal error: ss/context.h".
    # The 4.x tree compiles through KernelSU/kernel/Kbuild: append the missing
    # -I there (keeping both existing paths), then gate on it so a kernel without
    # that include can never be produced. The 3.x SUSFS line has no Kbuild and no
    # feature/selinux_hide.c, so there is nothing to patch for it.
    if [ -f KernelSU/kernel/Kbuild ]; then
        if ! grep -q 'security/selinux/ss' KernelSU/kernel/Kbuild; then
            sed -i 's|-I\$(srctree)/security/selinux/include|-I$(srctree)/security/selinux/include -I$(srctree)/security/selinux/ss|' KernelSU/kernel/Kbuild
        fi
        if ! grep -q 'security/selinux/ss' KernelSU/kernel/Kbuild; then
            echo "FATAL: [KernelSU/kernel/Kbuild] does not carry -I\$(srctree)/security/selinux/ss."
            echo "       (the 4.x selinux_hide.c includes <ss/...>, the build would fail)"
            exit 1
        fi
        echo "KernelSU/kernel/Kbuild: security/selinux/ss include is in place."
    else
        echo "NOTE: KernelSU/kernel/Kbuild not present (3.x SUSFS tree) - the security/selinux/ss include is not needed there."
    fi

    # t20: 4.19 has no MODULE_IMPORT_NS (it arrives with 5.16) while SukiSU v4.2.0's
    # kernel/core/init.c calls it in both branches of a >=6.13 guard. On 4.19 the
    # preprocessor leaves the token in place, clang reads it as an untyped function
    # definition and -Werror turns that into a hard error:
    #   kernel/core/init.c:244:1: error: type specifier missing, defaults to 'int'
    # Replace that guard block with a no-op definition and drop the two call lines
    # (expanding a no-op macro while keeping a call would leave a bare ';' at file
    # scope, which -Werror can also reject). Only the 4.x trees carry this file -
    # the 3.x SUSFS line does not, so the whole block is skipped there (an
    # unconditional sed would abort the script under `set -e`).
    if [ -f KernelSU/kernel/core/init.c ]; then
        if ! grep -q '^#ifndef MODULE_IMPORT_NS$' KernelSU/kernel/core/init.c; then
            sed -i '/^#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)$/,/^#endif$/{
                s|^#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)$|#ifndef MODULE_IMPORT_NS\n#define MODULE_IMPORT_NS(x)|
                /^[[:space:]]*MODULE_IMPORT_NS(/d
                /^#else$/d
            }' KernelSU/kernel/core/init.c
        fi
        if ! grep -q '^#define MODULE_IMPORT_NS' KernelSU/kernel/core/init.c; then
            echo "FATAL: [KernelSU/kernel/core/init.c] has no MODULE_IMPORT_NS definition."
            exit 1
        fi
        if grep -q '^[[:space:]]*MODULE_IMPORT_NS(' KernelSU/kernel/core/init.c; then
            echo "FATAL: [KernelSU/kernel/core/init.c] still calls MODULE_IMPORT_NS (bare ';' at file scope under -Werror)."
            exit 1
        fi
        echo "KernelSU/kernel/core/init.c: MODULE_IMPORT_NS no-op in place, both calls removed."
    else
        echo "NOTE: KernelSU/kernel/core/init.c not present (3.x SUSFS tree) - the MODULE_IMPORT_NS compat patch is not needed."
    fi

    # t24: 4.19 API/header sweep, see enuma_kernel_build/KSU-4.19-COMPAT-SWEEP.md.
    # Four mechanical fixes plus a runtime-resolved path_mount(). Each fix is
    # guarded by its own grep, so re-running the script is a no-op; the traps at
    # the end turn a missed fix into a hard failure instead of another ~21 minute
    # build cycle. Only the 4.x trees carry these files, so the 3.x SUSFS line
    # skips the whole block (an unconditional sed would abort under `set -e`).
    if [ -f KernelSU/kernel/feature/sucompat.c ]; then
        KSUK=KernelSU/kernel
        # (1) linux/pgtable.h (5.11+): sucompat.c uses no pgtable symbol at all
        if grep -q '#include <linux/pgtable.h>' "$KSUK/feature/sucompat.c"; then
            sed -i '/#include <linux\/pgtable.h>/d' "$KSUK/feature/sucompat.c"
        fi
        # (2) linux/minmax.h (5.10+): min()/max() live in linux/kernel.h on 4.19
        sed -i 's|#include <linux/minmax.h>|#include <linux/kernel.h>|' "$KSUK/sulog/event.c"
        # (3) uapi/linux/mount.h (5.2+): MS_PRIVATE/MS_REC are in uapi/linux/fs.h
        sed -i 's|#include <uapi/linux/mount.h>|#include <linux/fs.h>|' "$KSUK/infra/su_mount_ns.c"
        # (4) TWA_RESUME (5.9+): 4.19 task_work_add() takes a plain bool
        sed -i 's/\bTWA_RESUME\b/true/g' "$KSUK/policy/allowlist.c" "$KSUK/supercall/supercall.c"
        # (5) path_mount() (5.2+): resolve at runtime, degrade with one clear log line
        if ! grep -q 't24: path_mount runtime resolve' "$KSUK/infra/su_mount_ns.c"; then
            sed -i 's|^#include "infra/su_mount_ns.h"$|#include "infra/su_mount_ns.h"\n#include "infra/symbol_resolver.h" /* t24 */|' "$KSUK/infra/su_mount_ns.c"
            sed -i 's|^extern int path_mount(.*$|/* t24: path_mount() is 5.2+ only; the wrapper below resolves it at runtime */|' "$KSUK/infra/su_mount_ns.c"
            sed -i 's|^[[:space:]]*void \*data_page);$|static int ksu_path_mount_compat(const char *dev_name, struct path *path, const char *type_page, unsigned long flags, void *data_page);|' "$KSUK/infra/su_mount_ns.c"
            sed -i 's#\bpath_mount(NULL, &root_path, NULL, MS_PRIVATE | MS_REC, NULL)#ksu_path_mount_compat(NULL, \&root_path, NULL, MS_PRIVATE | MS_REC, NULL)#' "$KSUK/infra/su_mount_ns.c"
            cat >> "$KSUK/infra/su_mount_ns.c" <<'KSU419EOF'

/* t24: path_mount runtime resolve (Linux 4.19 has no path_mount(); it is 5.2+).
 * The symbol is looked up with the existing kallsyms resolver; when it is absent
 * one explicit line is logged and the caller sees -ENOSYS.
 * Consequence: on a kernel without path_mount() the mount-propagation step is
 * skipped (feature degradation, documented in the delivery notes). */
static int (*ksu_path_mount_fn)(const char *dev_name, struct path *path,
                                const char *type_page, unsigned long flags, void *data_page);
static bool ksu_path_mount_warned;

static int ksu_path_mount_compat(const char *dev_name, struct path *path,
                                 const char *type_page, unsigned long flags, void *data_page)
{
    if (!ksu_path_mount_fn)
        ksu_path_mount_fn = (void *)ksu_resolve_symbol_for_functable_hook("path_mount");
    if (!ksu_path_mount_fn) {
        if (!ksu_path_mount_warned) {
            pr_warn("t24: path_mount() is not available on this kernel (pre-5.2) - mount propagation setup skipped\n");
            ksu_path_mount_warned = true;
        }
        return -ENOSYS;
    }
    return ksu_path_mount_fn(dev_name, path, type_page, flags, data_page);
}
KSU419EOF
        fi
        # traps: any residue means the sweep did not land -> fail loudly
        if grep -q '#include <linux/pgtable.h>' "$KSUK/feature/sucompat.c"; then
            echo "FATAL: [feature/sucompat.c] still includes <linux/pgtable.h> (5.11+ header)."
            exit 1
        fi
        if grep -q '#include <linux/minmax.h>' "$KSUK/sulog/event.c"; then
            echo "FATAL: [sulog/event.c] still includes <linux/minmax.h> (5.10+ header)."
            exit 1
        fi
        if grep -q '#include <uapi/linux/mount.h>' "$KSUK/infra/su_mount_ns.c"; then
            echo "FATAL: [infra/su_mount_ns.c] still includes <uapi/linux/mount.h> (5.2+ header)."
            exit 1
        fi
        if grep -rq '\bTWA_RESUME\b' "$KSUK"; then
            echo "FATAL: TWA_RESUME (5.9+ enum) is still present in the 4.x KernelSU tree."
            exit 1
        fi
        if grep -q '^extern int path_mount(' "$KSUK/infra/su_mount_ns.c"; then
            echo "FATAL: [infra/su_mount_ns.c] still declares extern path_mount()."
            exit 1
        fi
        if ! grep -q 'ksu_path_mount_compat' "$KSUK/infra/su_mount_ns.c"; then
            echo "FATAL: [infra/su_mount_ns.c] has no ksu_path_mount_compat wrapper."
            exit 1
        fi
        echo "4.19 compat sweep applied: pgtable/minmax/uapi-mount headers, TWA_RESUME, path_mount runtime resolve."
    else
        echo "NOTE: KernelSU/kernel/feature/sucompat.c not present (3.x SUSFS tree) - the 4.19 compat sweep is not needed."
    fi

    if [ "$WITH_SUSFS" -eq 1 ]; then
        # Without the SUSFS glue in the KernelSU tree the SUSFS line would only
        # look like SUSFS: fail loudly instead of producing a fake kernel.
        if ! grep -q '^config KSU_SUSFS$' KernelSU/kernel/Kconfig; then
            echo "FATAL: KernelSU tree [$KSU_REF] has no SUSFS support (CONFIG_KSU_SUSFS is missing)."
            exit 1
        fi
    fi
else
    echo "KSU is disabled"
fi


echo "Cleaning..."

rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing kernel (repo: https://github.com/liyafe1997/AnyKernel3)"
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

# Add date to local version
local_version_str="-perf"
local_version_date_str="-$(date +%Y%m%d)-${GIT_COMMIT_ID}-perf"

sed -i "s/${local_version_str}/${local_version_date_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

# ------------- Building for AOSP -------------
# Skipped when MIUI_ONLY=1 (default): the MIUI block below builds the same kernel
# with the MIUI config, so building both only doubles the build time.
#
# NOT VERIFIED (t3/M1): the GitHub Actions workflow always passes MIUI_ONLY=1, so
# this whole AOSP block is never exercised by CI. The AOSP variant is out of scope
# for this delivery (Q5) - MIUI_ONLY=0 is kept for local/manual use only and has
# not been validated here.

if [ "$MIUI_ONLY" -eq 0 ]; then

echo "Building for AOSP......"
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

if [ $KSU_ENABLE -eq 1 ]; then
    # KSU config block (AOSP): clean line = KSU + KPROBES + EXT4_FS with KPM **off**
    # (t17: KernelSU v4.2.0's kernel/kpm/kpm.c uses the 5.0+ two-argument
    # access_ok() and does not compile on 4.19 - see the gate below),
    # SUSFS line = KSU + KSU_MANUAL_HOOK + KSU_SUSFS + KSU_SUSFS_* + KPM.
    if [ "$WITH_SUSFS" -eq 1 ]; then
        scripts/config --file out/.config \
        -e KSU \
        -e KSU_MANUAL_HOOK \
        -e KSU_SUSFS \
        -e KSU_SUSFS_HAS_MAGIC_MOUNT \
        -d KSU_SUSFS_SUS_PATH \
        -e KSU_SUSFS_SUS_MOUNT \
        -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
        -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
        -e KSU_SUSFS_SUS_KSTAT \
        -d KSU_SUSFS_SUS_OVERLAYFS \
        -e KSU_SUSFS_TRY_UMOUNT \
        -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
        -e KSU_SUSFS_SPOOF_UNAME \
        -e KSU_SUSFS_ENABLE_LOG \
        -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
        -d KSU_SUSFS_OPEN_REDIRECT \
        -d KSU_SUSFS_SUS_SU \
        -e KPM
    else
        scripts/config --file out/.config \
        -e KSU \
        -e KPROBES \
        -e EXT4_FS \
        -d KPM
    fi

    # scripts/config does not resolve dependencies: re-solve, then gate.
    make $MAKE_ARGS olddefconfig

    require_config KSU
    if [ "$WITH_SUSFS" -eq 1 ]; then
        require_config KPM
        require_config KSU_SUSFS
        forbid_config KSU_SUSFS_SUS_SU
    else
        require_config KPROBES
        require_config EXT4_FS
        forbid_config KPM
        forbid_symbol KSU_MANUAL_HOOK
    fi
else
    scripts/config --file out/.config -d KSU
fi

make $MAKE_ARGS -j$(nproc)


if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "The file [out/arch/arm64/boot/Image] exists. AOSP Build successfully."
else
    echo "The file [out/arch/arm64/boot/Image] does not exist. Seems AOSP build failed."
    exit 1
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

rm -rf anykernel/kernels/

mkdir -p anykernel/kernels/

# Patch for SukiSU KPM support. 
if [ $KSU_ENABLE -eq 1 ] && [ "$WITH_SUSFS" -eq 1 ]; then
    cd out/arch/arm64/boot/
    # KPM image patch: SUSFS line only. The clean line builds with CONFIG_KPM=n
    # (see the gates above), so patching its image would be meaningless.
    # Version pinned to 0.12.0 = the release used by the last known-good package.
    wget -q https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
    chmod +x patch_linux
    ./patch_linux -i Image -o oImage
    if [ ! -f oImage ]; then
        echo "FATAL: KPM patch did not produce [oImage]."
        exit 1
    fi
    rm Image
    mv oImage Image
    cd -
fi

cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

cd anykernel 

ZIP_FILENAME=Kernel_AOSP_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip

zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip

mv $ZIP_FILENAME ../

cd ..


echo "Build for AOSP finished."

fi

# ------------- End of Building for AOSP -------------
#  If you don't need AOSP you can comment out the above block [Building for AOSP]


# ------------- Building for MIUI -------------


echo "Clearning [out/] and build for MIUI....."
rm -rf out/

dts_source=arch/arm64/boot/dts/vendor/qcom

# Backup dts
cp -a ${dts_source} .dts.bak

# Correct panel dimensions on MIUI builds
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2*
sed -i 's/<155>/<1544>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<155>/<1545>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j2*

# Enable back mi smartfps while disabling qsync min refresh-rate
sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*

# Enable back refresh rates supported on MIUI
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi


# Enable back brightness control from dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi


make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

if [ $KSU_ENABLE -eq 1 ]; then
    # KSU config block (MIUI): clean line = KSU + KPROBES + EXT4_FS with KPM **off**
    # (t17: KernelSU v4.2.0's kernel/kpm/kpm.c uses the 5.0+ two-argument
    # access_ok() and does not compile on 4.19 - see the gate below),
    # SUSFS line = KSU + KSU_MANUAL_HOOK + KSU_SUSFS + KSU_SUSFS_* + KPM.
    if [ "$WITH_SUSFS" -eq 1 ]; then
        scripts/config --file out/.config \
        -e KSU \
        -e KSU_MANUAL_HOOK \
        -e KSU_SUSFS \
        -e KSU_SUSFS_HAS_MAGIC_MOUNT \
        -d KSU_SUSFS_SUS_PATH \
        -e KSU_SUSFS_SUS_MOUNT \
        -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
        -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
        -e KSU_SUSFS_SUS_KSTAT \
        -d KSU_SUSFS_SUS_OVERLAYFS \
        -e KSU_SUSFS_TRY_UMOUNT \
        -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
        -e KSU_SUSFS_SPOOF_UNAME \
        -e KSU_SUSFS_ENABLE_LOG \
        -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
        -d KSU_SUSFS_OPEN_REDIRECT \
        -d KSU_SUSFS_SUS_SU \
        -e KPM
    else
        scripts/config --file out/.config \
        -e KSU \
        -e KPROBES \
        -e EXT4_FS \
        -d KPM
    fi

    # scripts/config does not resolve dependencies: re-solve, then gate.
    make $MAKE_ARGS olddefconfig

    require_config KSU
    if [ "$WITH_SUSFS" -eq 1 ]; then
        require_config KPM
        require_config KSU_SUSFS
        forbid_config KSU_SUSFS_SUS_SU
    else
        require_config KPROBES
        require_config EXT4_FS
        forbid_config KPM
        forbid_symbol KSU_MANUAL_HOOK
    fi
else
    scripts/config --file out/.config -d KSU
fi


# MIUI-only fine tuning (inherited verbatim from build.sh.orig; the block itself
# is frozen by SPEC §8 item 12).
# t3/L1: KPERFEVENTS, MIHW and MI_MEMORY_SYSFS have NO definition in this Kconfig
# tree (KPERFEVENTS matches nothing at all; MIHW / MI_MEMORY_SYSFS only appear in
# the *stock* defconfigs), so `make` drops those three silently - they are no-ops
# inherited from the original script, not features, and are intentionally kept.
# t13/F3: the two lines `-d CONFIG_MODULE_SIG_SHA512` / `-d CONFIG_MODULE_SIG_HASH`
# have been deleted here: scripts/config prefixes every argument with "CONFIG_",
# so they only ever wrote the bogus symbols CONFIG_CONFIG_MODULE_SIG_SHA512 /
# CONFIG_CONFIG_MODULE_SIG_HASH (dropped again by the next olddefconfig) and
# never disabled anything. They are deliberately NOT re-added as
# `-d MODULE_SIG_SHA512` / `-d MODULE_SIG_HASH`: that would make them effective
# and silently change module signing behaviour.
scripts/config --file out/.config \
    --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
    -e PERF_CRITICAL_RT_TASK	\
    -e SF_BINDER		\
    -e OVERLAY_FS		\
    -d DEBUG_FS \
    -e MIGT \
    -e MIGT_ENERGY_MODEL \
    -e MIHW \
    -e PACKAGE_RUNTIME_INFO \
    -e BINDER_OPT \
    -e KPERFEVENTS \
    -e MILLET \
    -e PERF_HUMANTASK \
    -d LTO_CLANG \
    -d LOCALVERSION_AUTO \
    -e SF_BINDER \
    -e XIAOMI_MIUI \
    -d MI_MEMORY_SYSFS \
    -e TASK_DELAY_ACCT \
    -e MIUI_ZRAM_MEMORY_TRACKING \
    -e MI_FRAGMENTION \
    -e PERF_HELPER \
    -e BOOTUP_RECLAIM \
    -e MI_RECLAIM \
    -e RTMM \

# t3/L2: this MIUI-only block runs after the KSU gates above and was never
# re-validated - a symbol changed here could drop KernelSU / KPROBES / EXT4_FS and
# still build "green". Re-solve the dependencies (exactly what the following
# `make` would do through syncconfig, so the resulting .config is unchanged) and
# re-run the same gates before compiling.
make $MAKE_ARGS olddefconfig
if [ $KSU_ENABLE -eq 1 ]; then
    require_config KSU
    if [ "$WITH_SUSFS" -eq 1 ]; then
        require_config KPM
        require_config KSU_SUSFS
        forbid_config KSU_SUSFS_SUS_SU
    else
        require_config KPROBES
        require_config EXT4_FS
        forbid_config KPM
        forbid_symbol KSU_MANUAL_HOOK
    fi
fi

make $MAKE_ARGS -j$(nproc)



if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "The file [out/arch/arm64/boot/Image] exists. MIUI Build successfully."
else
    echo "The file [out/arch/arm64/boot/Image] does not exist. Seems MIUI build failed."
    exit 1
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb


# Restore modified dts
rm -rf ${dts_source}
mv .dts.bak ${dts_source}

rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/

# Patch for SukiSU KPM support. 
if [ $KSU_ENABLE -eq 1 ] && [ "$WITH_SUSFS" -eq 1 ]; then
    cd out/arch/arm64/boot/
    # KPM image patch: SUSFS line only. The clean line builds with CONFIG_KPM=n
    # (see the gates above), so patching its image would be meaningless.
    # Version pinned to 0.12.0 = the release used by the last known-good package.
    wget -q https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
    chmod +x patch_linux
    ./patch_linux -i Image -o oImage
    if [ ! -f oImage ]; then
        echo "FATAL: KPM patch did not produce [oImage]."
        exit 1
    fi
    rm Image
    mv oImage Image
    cd -
fi

cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

echo "Build for MIUI finished."

# Restore local version string
sed -i "s/${local_version_date_str}/${local_version_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

# ------------- End of Building for MIUI -------------
#  If you don't need MIUI you can comment out the above block [Building for MIUI]


cd anykernel 

ZIP_FILENAME=Kernel_MIUI_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip

zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip

mv $ZIP_FILENAME ../

cd ..

echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
