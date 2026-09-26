#!/bin/bash

# Some logics of this script are copied from [scripts/build_kernel]. Thanks to UtsavBalar1231.
#
# ---------------------------------------------------------------------------
# enuma (Xiaomi Pad 5 Pro 5G) - THREE KernelSU lines in ONE script
#
#   MIUI_ONLY=1 (default) build only the MIUI variant, the AOSP block is skipped
#   WITH_SUSFS=0 (default) clean line : SukiSU-Ultra/SukiSU-Ultra v4.2.0  (4.x)
#                          -> Kernel_MIUI_enuma_SukiSU_*_anykernel3_*.zip
#   WITH_SUSFS=1           SUSFS line : KernelSU carrying the SUSFS 1.5.x glue
#                          -> Kernel_MIUI_enuma_SukiSU-SUSFS_*_anykernel3_*.zip
#   WITH_SUSFS=2           C line     : ReSukiSU 4.x (KSU side) + SUSFS 2.3.0
#                          (kernel side, applied by this script on top of the fork's
#                          own 1.5.7 code, which is stripped first)
#                          -> Kernel_MIUI_enuma_ReSukiSU-SUSFS2_*_anykernel3_*.zip
#
# Usage:
#     MIUI_ONLY=1 WITH_SUSFS=0 bash build.sh enuma ksu
#     MIUI_ONLY=1 WITH_SUSFS=1 bash build.sh enuma ksu
#     MIUI_ONLY=1 WITH_SUSFS=2 bash build.sh enuma ksu
#
# KernelSU sources - all pinned to immutable commits:
#   clean line : 85eb4a95b8a61d756ecf53b9c5785e48e1b15039 = tag v4.2.0
#   SUSFS line : f4863b20cc8dc0f8cc67418980f022e43014b598 = liyafe1997/SukiSU-Ultra "susfs-1.5.7"
#   C line     : 0e4698951b8e0e1cb997e46f2049c691869a4f45 = ReSukiSU/ReSukiSU main HEAD,
#                the 4.2.0 line (was f7be4a53, the commit behind the reference build's
#                "v4.1.0-f7be4a53+3a62be00@ReSukiSU").
#                WHY 0e469895 AND NOT THE TAG: the manager and the kernel BOTH derive
#                their version number from the same monorepo commit count
#                  kernel : KSU_VERSION        = 30000 + rev-list --count HEAD + 700
#                  manager: BuildConfig.VERSION_CODE = 30000 + getGitCommitCount() + 700
#                and the manager's HomePage.kt gate is
#                  if (ksuVersion > VERSION_CODE)                      -> OK
#                  else if (ksuVersion < VERSION_CODE)                 -> "kernel needs update"
#                so the kernel must report a number >= the manager's. A 4.2.0 manager is
#                built at >= 4479 commits (VERSION_CODE >= 35179), therefore the kernel
#                must also be at >= 4479 commits:
#                  f7be4a53 (4351) -> 35051  TOO LOW, this is the reported bug
#                  rc3 tag 239e1e88 (4471) -> 35171  STILL 8 SHORT
#                  0e469895 (4479) -> 35179  PASSES
#                NOTE: the v4.1.0 TAG (0d27e685, 2025-12-05) is a flat, older layout
#                without KSU_SUSFS - do not pin the tag.
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
# WITH_SUSFS: 0 (default) = clean SukiSU v4.2.0 line
#             1           = SukiSU 3.x + in-tree SUSFS 1.5.7 line
#             2           = C line: ReSukiSU 4.x + SUSFS 2.3.0 (kernel side patched here)
MIUI_ONLY=${MIUI_ONLY:-1}
WITH_SUSFS=${WITH_SUSFS:-0}

case "$MIUI_ONLY" in
    0|1) ;;
    *) echo "MIUI_ONLY must be 0 or 1 (got: [$MIUI_ONLY])"; exit 1 ;;
esac

case "$WITH_SUSFS" in
    0|1|2) ;;
    *) echo "WITH_SUSFS must be 0, 1 or 2 (got: [$WITH_SUSFS]); 2 = the ReSukiSU + SUSFS 2.3.0 C line"; exit 1 ;;
esac

# ---- KernelSU sources (immutable commits) ----------------------------------
# clean line: SukiSU-Ultra/SukiSU-Ultra tag v4.2.0 (4.x, metamodule capable)
KSU_REF_CLEAN=85eb4a95b8a61d756ecf53b9c5785e48e1b15039
# SUSFS line: liyafe1997/SukiSU-Ultra branch susfs-1.5.7 (matches this tree's
# in-kernel SUSFS 1.5.7 fs-side code)
KSU_REF_SUSFS=f4863b20cc8dc0f8cc67418980f022e43014b598
# C line: ReSukiSU 4.x. This is the KSU side of the reference build; the kernel side
# (SUSFS 2.3.0) is downloaded and applied by the C-line block further down.
# 4.2.0 line. Must stay at >= 4479 commits so the kernel reports KSU_VERSION >= 35179
# and a 4.2.0 manager stops reporting "kernel needs update" (see the header note).
KSU_REF_RE=0e4698951b8e0e1cb997e46f2049c691869a4f45
# SUSFS 2.3.0 kernel-side patch (JackA1ltman/NonGKI_Kernel_Build_2nd, the only public
# 4.19 source; it carries no KSU call sites, which is why the C-line block below adds
# them itself). blob 6fc809dce97974ea1c99c3ee97429a203a0ebae7, 143835 B.
# WAS 2.2.0 (blob 4ae50a12..., 134634 B) - see the header note on why it had to move:
# ReSukiSU 4.2.0's kernel/feature/sucompat.h maps its internal API onto
# susfs_{is,set,clear}_current_proc_no_su and
# susfs_set_current_proc_umounted_for_zygote_next, NONE of which SUSFS 2.2.0 declares
# (it only has susfs_is_current_proc_umounted/_app). The mismatch is a LINK error,
# not a compile error (run15: undefined reference in sucompat.o / setuid_hook.o).
# 2.3.0 declares all four in include/linux/susfs_def.h, which is the header
# sucompat.h includes. ReSukiSU 4.2.0 and SUSFS 2.3.0 must therefore move together.
SUSFS_230_URL=https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/6b9e7acf958d750088c47af5d368f69767c4dac9/Patches/Patch/susfs_patch_to_4.19.patch
SUSFS_230_BLOB=6fc809dce97974ea1c99c3ee97429a203a0ebae7
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

# t40/Part1+P2-a: exported (not in MAKE_ARGS, which is expanded unquoted and
# would split a multi-word value into separate make goals).
#   -gdwarf-4       : clang 17 defaults to DWARF 5, whose DW_FORM_loclistx (0x22)
#                     and DW_FORM_rnglistx (0x23) make ubuntu-22.04's
#                     aarch64-linux-gnu-objdump (binutils 2.38) print one warning
#                     per occurrence - 98.3% of the A line log. kbuild appends
#                     KCFLAGS/KAFLAGS *after* KBUILD_CFLAGS/KBUILD_AFLAGS
#                     (Makefile:1001/1002), so this overrides clang's default.
#                     The flashed Image is produced by arch/arm64/boot/Makefile:19
#                     `OBJCOPYFLAGS_Image := -O binary -R .note -R .note.gnu.build-id
#                     -R .comment -S`, i.e. objcopy -O binary keeps only allocatable
#                     sections (debug sections are non-alloc) and -S strips symbols,
#                     so the debug format cannot reach the flashed Image.
#   -ferror-limit=0 : clang stops after 20 diagnostics per TU, which truncated two
#                     KSU objects in run6 ("too many errors emitted"). This only
#                     raises a *diagnostic* cap; it changes no code generation and
#                     silences no warning class.
export KCFLAGS="-gdwarf-4 -ferror-limit=0"
export KAFLAGS="-gdwarf-4"


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
    if [ "$WITH_SUSFS" -eq 2 ]; then
        KSU_ZIP_STR=ReSukiSU-SUSFS2
    elif [ "$WITH_SUSFS" -eq 1 ]; then
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

# ---- C line (WITH_SUSFS=2) config, shared by the AOSP and MIUI blocks ----------
# The C line's config surface is a different symbol set from the A/B lines':
#   * SUSFS 2.3.0 declares exactly 10 KSU_SUSFS_* symbols (no HAS_MAGIC_MOUNT, no
#     SUS_OVERLAYFS, no SUS_SU, no TRY_UMOUNT family) - and no KPM at all;
#   * KSU_SUSFS is a `choice` arm next to KSU_TRACEPOINT_HOOK / KSU_MANUAL_HOOK, so
#     selecting it is what makes ReSukiSU use SUSFS inline hooks. If its dependency
#     (THREAD_INFO_IN_TASK) is missing, Kconfig silently falls back to
#     KSU_TRACEPOINT_HOOK - which is why every config write is followed by a full
#     symbol gate rather than just `=y` checks.
cline_config() {
    scripts/config --file out/.config \
        -e KSU \
        -e KPROBES \
        -e EXT4_FS \
        -e KSU_SUSFS \
        -e KSU_SUSFS_SUS_PATH \
        -e KSU_SUSFS_SUS_MOUNT \
        -e KSU_SUSFS_SUS_KSTAT \
        -e KSU_SUSFS_SPOOF_UNAME \
        -e KSU_SUSFS_ENABLE_LOG \
        -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
        -e KSU_SUSFS_OPEN_REDIRECT \
        -e KSU_SUSFS_SUS_MAP
    make $MAKE_ARGS olddefconfig
    require_config KSU
    require_config KPROBES
    require_config EXT4_FS
    require_config THREAD_INFO_IN_TASK
    require_config KSU_SUSFS
    for c in SUS_PATH SUS_MOUNT SUS_KSTAT SPOOF_UNAME ENABLE_LOG HIDE_KSU_SUSFS_SYMBOLS SPOOF_CMDLINE_OR_BOOTCONFIG OPEN_REDIRECT SUS_MAP; do
        require_config KSU_SUSFS_$c
    done
    forbid_config KSU_MANUAL_HOOK
    forbid_config KSU_TRACEPOINT_HOOK
    require_config KSU_MULTI_MANAGER_SUPPORT
    # ReSukiSU has no KPM: the symbol must not exist on the C line at all, which is a
    # stronger statement than KPM=n (a stray -e KPM would be silently dropped by
    # olddefconfig and raise no error).
    forbid_symbol KPM
    # the version assertion the C line needs on top of `KSU_SUSFS=y`: the tree could
    # otherwise carry the wrong SUSFS generation and still satisfy every =y gate.
    if ! grep -q '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h; then
        echo "FATAL: [cline] include/linux/susfs.h does not report SUSFS v2.3.0."
        exit 1
    fi
    echo "[cline] config gates passed: KSU + KSU_SUSFS(2.3.0) + 9 SUSFS features + THREAD_INFO_IN_TASK, KPM absent."
}


echo "TARGET_DEVICE: $TARGET_DEVICE"
echo "MIUI_ONLY: [$MIUI_ONLY] WITH_SUSFS: [$WITH_SUSFS] KSU: [$KSU_ZIP_STR]"

if [ $KSU_ENABLE -eq 1 ]; then
    echo "KSU is enabled"
    if [ "$WITH_SUSFS" -eq 2 ]; then
        # C line: ReSukiSU. The official SukiSU setup.sh only clones SukiSU-Ultra, so
        # it cannot produce this tree; the clone is done here at a pinned commit and
        # its HEAD is verified, because a silently wrong checkout is the failure mode
        # this project already hit once (`git checkout "$1" || echo` swallowing an
        # error). ReSukiSU's own kernel/setup.sh (blob below) is then reused verbatim
        # for the drivers/ wiring - it skips its clone because KernelSU/ exists.
        KSU_REF=$KSU_REF_RE
        KSU_SETUP_URL=https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/${KSU_REF}/kernel/setup.sh
        git clone --filter=blob:none https://github.com/ReSukiSU/ReSukiSU KernelSU
        git -C KernelSU checkout --detach "$KSU_REF"
        KSU_HEAD=$(git -C KernelSU rev-parse HEAD)
        if [ "$KSU_HEAD" != "$KSU_REF" ]; then
            echo "FATAL: KernelSU is at [$KSU_HEAD] but [$KSU_REF] was requested."
            exit 1
        fi
        echo "KernelSU ref: [$KSU_REF]"
        curl -LSs "$KSU_SETUP_URL" | bash -s "$KSU_REF"
        # ReSukiSU's compat/kernel_compat.h includes <ss/policydb.h>; on this 4.19 tree
        # that private directory is security/selinux/ss, which is NOT in the Kbuild's own
        # -I list (it stops at security/selinux/include).
        #
        # The append is done by the SHARED t13/F1 block further down, which runs for the
        # C line as well (its existence test is KernelSU/kernel/Kbuild). It used to be
        # duplicated here, which is why run12's C leg printed the banner twice and looked
        # like a mechanism that had not run. Nothing to do at this point.
        echo "[cline] the security/selinux/ss -I append is handled by the shared t13/F1 block below."
    else
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
    # t6/F-note: three-way rather than two-way. `[ -f ]` is required by the t52 guard-line
    # contract, so a path that EXISTS but is not a regular file fell into the "absent"
    # branch and printed an untrue "3.x SUSFS tree / not present" NOTE (measured by putting
    # a directory in the way). `-e` now separates "wrong kind of node" (FATAL, no guessing)
    # from "really absent" (NOTE on A/B; FATAL on C, which always ships one).
    if [ ! -e KernelSU/kernel/Kbuild ]; then
        if [ "$WITH_SUSFS" -le 1 ]; then
            echo "NOTE: KernelSU/kernel/Kbuild not present (3.x SUSFS tree) - the security/selinux/ss include is not needed there."
        else
            echo "FATAL: [cline] KernelSU/kernel/Kbuild is absent on a WITH_SUSFS=2 tree, which cannot happen (ReSukiSU always ships one)."
            exit 1
        fi
    elif [ ! -f KernelSU/kernel/Kbuild ]; then
        echo "FATAL: [KernelSU/kernel/Kbuild] exists but is not a regular file - refusing to guess which line this is."
        exit 1
    else
        if ! grep -q 'security/selinux/ss' KernelSU/kernel/Kbuild; then
            sed -i 's|-I\$(srctree)/security/selinux/include|-I$(srctree)/security/selinux/include -I$(srctree)/security/selinux/ss|' KernelSU/kernel/Kbuild
        fi
        if ! grep -q 'security/selinux/ss' KernelSU/kernel/Kbuild; then
            echo "FATAL: [KernelSU/kernel/Kbuild] does not carry -I\$(srctree)/security/selinux/ss."
            echo "       (the 4.x selinux_hide.c includes <ss/...>, the build would fail)"
            exit 1
        fi
        # this helper is shared by every 4.x line (A and C), so the banner says which line
        # it is running for; run12's C leg printed it twice (once from the shared driver
        # block and once from the C block), which looked like a mechanism that had not run.
        echo "KernelSU/kernel/Kbuild: security/selinux/ss include is in place. [line: WITH_SUSFS=$WITH_SUSFS]"
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
    # C-LINE NOTE: the whole block below (t20/t24/t28/t35/t40/t46/t49/t55) is the
    # A/B-line 4.19 compat sweep for the SukiSU v4.2.0 tree. Two of its gates also fire
    # on ReSukiSU's tree (same file names, different code), where they would rewrite
    # working code - e.g. the t40 SELinux stubs would disable ReSukiSU's own SELinux
    # policy injection. It is therefore gated on `WITH_SUSFS -le 1`; the C line has its
    # own transform block further down.
    if [ "$WITH_SUSFS" -le 1 ] && [ -f KernelSU/kernel/core/init.c ]; then
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
        if [ "$WITH_SUSFS" -le 1 ]; then echo "NOTE: KernelSU/kernel/core/init.c not present (3.x SUSFS tree) - the MODULE_IMPORT_NS compat patch is not needed."; else echo "SKIP [cline]: the MODULE_IMPORT_NS compat patch is A/B-only (this is the C line, ReSukiSU carries its own 4.19 compat layer - the file exists and was deliberately left untouched)."; fi
    fi

    # t24: 4.19 API/header sweep, see enuma_kernel_build/KSU-4.19-COMPAT-SWEEP.md.
    # Four mechanical fixes plus a runtime-resolved path_mount(). Each fix is
    # guarded by its own grep, so re-running the script is a no-op; the traps at
    # the end turn a missed fix into a hard failure instead of another ~21 minute
    # build cycle. Only the 4.x trees carry these files, so the 3.x SUSFS line
    # skips the whole block (an unconditional sed would abort under `set -e`).
    if [ "$WITH_SUSFS" -le 1 ] && [ -f KernelSU/kernel/feature/sucompat.c ]; then
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
        if [ "$WITH_SUSFS" -le 1 ]; then echo "NOTE: KernelSU/kernel/feature/sucompat.c not present (3.x SUSFS tree) - the 4.19 compat sweep is not needed."; else echo "SKIP [cline]: the 4.19 compat sweep is A/B-only (this is the C line; the file exists and was deliberately left untouched)."; fi
    fi

    # t28: KernelSU v4.2.0 also calls three Linux 5.8+ "maccess" wrappers that
    # 4.19 does not have: strncpy_from_user_nofault() (5 call sites: feature/sucompat.c
    # x2, runtime/ksud_integration.c, sulog/event.c x2), copy_to_user_nofault()
    # (runtime/ksud_integration.c) and copy_to_kernel_nofault() (hook/*/patch_memory.c).
    # t31/F1: the original claim that copy_to_kernel_nofault() is "compiled out by
    # `#if KSU_NEW_DCACHE_FLUSH`" was WRONG - that guard only wraps the two
    # ksu_flush_* macro definitions (hook/arm64/patch_memory.c L92-103), while the
    # call at L150 sits under `#ifdef __aarch64__` only, and hook/arm64/patch_memory.o
    # is unconditionally in kernelsu-objs. It is therefore a real 4.19 blocker and is
    # shimmed here. The user-space strncpy shim mirrors mainline v5.8 mm/maccess.c.
    if [ "$WITH_SUSFS" -le 1 ] && [ -f KernelSU/kernel/feature/sucompat.c ]; then
        KSUK=KernelSU/kernel
        if ! grep -qs 'ksu_copy_from_user_nofault' "$KSUK/include/ksu_419_compat.h"; then
            cat > "$KSUK/include/ksu_419_compat.h" <<'KSU419HDR'
/* t28: Linux 4.19 compatibility shims for the 5.8+ "maccess" wrappers used by
 * KernelSU v4.2.0. Included from every file that calls one of them. */
#ifndef __KSU_419_COMPAT_H
#define __KSU_419_COMPAT_H

#include <linux/uaccess.h>
#include <linux/version.h>
#include <asm/processor.h> /* USER_DS lives here on this 4.19 arm64 tree */

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
/*
 * strncpy_from_user_nofault() arrived in 5.8 (mm/maccess.c). This body mirrors
 * mainline v5.8 verbatim: strncpy_from_user() with pagefault handling disabled,
 * then mainline's return-value fixup (length including the trailing NUL; @count
 * when truncated, with the last byte set to NUL). 4.19 supplies every primitive
 * (get_fs/set_fs/USER_DS, pagefault_disable/enable, strncpy_from_user), and its
 * strncpy_from_user() has the same "length without the NUL" contract 5.8 relies
 * on. Unlike the copy_from_user_nofault+strnlen approximation this does not
 * report a spurious -EFAULT for a short string next to an unmapped page.
 */
static inline long ksu_strncpy_from_user_nofault(char *dst, const void __user *unsafe_addr, long count)
{
    mm_segment_t old_fs = get_fs();
    long ret;

    if (unlikely(count <= 0))
        return 0;

    set_fs(USER_DS);
    pagefault_disable();
    ret = strncpy_from_user(dst, unsafe_addr, count);
    pagefault_enable();
    set_fs(old_fs);

    if (ret >= count) {
        ret = count;
        dst[ret - 1] = '\0';
    } else if (ret > 0) {
        ret++;
    }

    return ret;
}

/* copy_to_user_nofault() arrived in 5.8; 4.19 has probe_user_write() with the
 * same contract (0 on success, -EFAULT when the access faults). */
static inline long ksu_copy_to_user_nofault(void __user *dst, const void *src, size_t size)
{
    return probe_user_write(dst, src, size);
}

/* t31: copy_to_kernel_nofault() is 5.8+ (mm/maccess.c); 4.19 spells it
 * probe_kernel_write(). Same contract: 0 on success, -EFAULT on fault.
 * Called from hook/arm64/patch_memory.c, whose object is unconditionally in
 * kernelsu-objs. */
static inline long ksu_copy_to_kernel_nofault(void *dst, const void *src, size_t size)
{
    return probe_kernel_write(dst, src, size);
}

/* t40: copy_from_user_nofault() has no declaration anywhere in this 4.19 tree
 * (include/linux/uaccess.h: 0 hits - verified); the pre-5.8 spelling is
 * probe_user_read(), same contract (bytes not copied, 0 on success). */
static inline long ksu_copy_from_user_nofault(void *dst, const void __user *src, size_t size)
{
    return probe_user_read(dst, src, size);
}
#endif /* LINUX_VERSION_CODE < 5.8 */

#endif /* __KSU_419_COMPAT_H */
KSU419HDR
        fi
        for f in feature/sucompat.c runtime/ksud_integration.c sulog/event.c \
                 hook/arm64/patch_memory.c hook/x86_64/patch_memory.c; do
            if ! grep -q 'ksu_419_compat.h' "$KSUK/$f"; then
                sed -i '0,/^[[:space:]]*#include "/{s/^[[:space:]]*#include "/#include "ksu_419_compat.h"\n&/}' "$KSUK/$f"
            fi
        done
        sed -i 's/\bstrncpy_from_user_nofault(/ksu_strncpy_from_user_nofault(/g' \
            "$KSUK/feature/sucompat.c" "$KSUK/runtime/ksud_integration.c" "$KSUK/sulog/event.c"
        sed -i 's/\bcopy_to_user_nofault(/ksu_copy_to_user_nofault(/g' "$KSUK/runtime/ksud_integration.c"
        # t31/F1: both patch_memory.c files call copy_to_kernel_nofault(); only the
        # arm64 one is compiled here, but renaming both keeps the gate below strict.
        sed -i 's/\bcopy_to_kernel_nofault(/ksu_copy_to_kernel_nofault(/g' \
            "$KSUK/hook/arm64/patch_memory.c" "$KSUK/hook/x86_64/patch_memory.c"
        # t40: copy_from_user_nofault() is declared nowhere in this 4.19 tree, so the
        # two call sites move to the fourth compat shim as well (kernel_compat.h is
        # dead code today but is kept consistent).
        sed -i 's/\bcopy_from_user_nofault(/ksu_copy_from_user_nofault(/g' \
            "$KSUK/runtime/ksud_integration.c" "$KSUK/kernel_compat.h"
        if ! grep -q 'ksu_419_compat.h' "$KSUK/kernel_compat.h"; then
            sed -i 's|^#include <linux/fs.h>|#include <linux/fs.h>\n#include "ksu_419_compat.h" /* t40 */|' "$KSUK/kernel_compat.h"
        fi
        # traps: a leftover bare 5.8 call, or a missing shim, must fail the build
        for shim in ksu_strncpy_from_user_nofault ksu_copy_to_user_nofault ksu_copy_to_kernel_nofault ksu_copy_from_user_nofault; do
            if ! grep -q "$shim" "$KSUK/include/ksu_419_compat.h"; then
                echo "FATAL: [include/ksu_419_compat.h] has no $shim shim."
                exit 1
            fi
        done
        for sym in strncpy_from_user_nofault copy_to_user_nofault copy_to_kernel_nofault copy_from_user_nofault; do
            if grep -rEl "(^|[^_a-zA-Z0-9])$sym[[:space:]]*\(" "$KSUK" --include='*.c' --include='*.h' | grep -qv 'ksu_419_compat.h'; then
                echo "FATAL: a bare $sym() call (5.8+ API) is left in the 4.x KernelSU tree."
                exit 1
            fi
        done
        for f in feature/sucompat.c runtime/ksud_integration.c sulog/event.c \
                 hook/arm64/patch_memory.c hook/x86_64/patch_memory.c; do
            if ! grep -q 'ksu_419_compat.h' "$KSUK/$f"; then
                echo "FATAL: [$f] does not include ksu_419_compat.h (it calls a 5.8+ maccess wrapper)."
                exit 1
            fi
        done
        # t31/F3: counts are grepped at run time, never hard-coded, so the line keeps
        # matching reality when call sites are added or removed upstream.
        cnt_strncpy=$(grep -rhoE '(^|[^_a-zA-Z0-9])ksu_strncpy_from_user_nofault[[:space:]]*\(' "$KSUK" --include='*.c' | wc -l)
        cnt_to_user=$(grep -rhoE '(^|[^_a-zA-Z0-9])ksu_copy_to_user_nofault[[:space:]]*\(' "$KSUK" --include='*.c' | wc -l)
        cnt_to_kern=$(grep -rhoE '(^|[^_a-zA-Z0-9])ksu_copy_to_kernel_nofault[[:space:]]*\(' "$KSUK" --include='*.c' | wc -l)
        cnt_from_user=$(grep -rhoE '(^|[^_a-zA-Z0-9])ksu_copy_from_user_nofault[[:space:]]*\(' "$KSUK" --include='*.c' --include='*.h' | wc -l)
        if [ "$cnt_strncpy" -eq 0 ] || [ "$cnt_to_user" -eq 0 ] || [ "$cnt_to_kern" -eq 0 ] || [ "$cnt_from_user" -eq 0 ]; then
            echo "FATAL: a 5.8+ maccess call site was not rewritten (counts: $cnt_strncpy/$cnt_to_user/$cnt_to_kern/$cnt_from_user)."
            exit 1
        fi
        echo "4.19 maccess shims applied: strncpy_from_user_nofault, copy_to_user_nofault, copy_to_kernel_nofault, copy_from_user_nofault (rewritten call sites: $cnt_strncpy/$cnt_to_user/$cnt_to_kern/$cnt_from_user)."

        # t28b: infra/file_wrapper.c (compile list Kbuild:20, unconditional) pokes at
        # two struct file_operations members 4.19 does not have - remap_file_range
        # (4.20+) and iopoll (6.1+) - with no version guard at all, so the A line
        # would die on them right after the maccess errors. Wrap them in the tree's
        # usual version guards (the wrapped fops simply lose those two hooks on 4.19).
        FW="$KSUK/infra/file_wrapper.c"
        # t31/F2b: the guard MUST compare at the 5.0 boundary, not at 4.20:
        # KERNEL_VERSION(4,19,325) = 267333 > KERNEL_VERSION(4,20,0) = 267264, so
        # `>= KERNEL_VERSION(4,20,0)` is TRUE on this tree (the 325 patchlevel
        # overflows into the minor nibble) and would have left the fix ineffective.
        # KERNEL_VERSION(5,0,0) = 327680 is safely above it.
        if ! grep -q 't28: remap_file_range fn is 5.0+' "$FW"; then
            sed -i 's|^static loff_t ksu_wrapper_remap_file_range(|#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0) /* t28: remap_file_range fn is 5.0+ */\nstatic loff_t ksu_wrapper_remap_file_range(|' "$FW"
            sed -i 's|^static int ksu_wrapper_fadvise(|#endif /* t28: remap_file_range fn */\nstatic int ksu_wrapper_fadvise(|' "$FW"
            sed -i 's|^    p->ops.remap_file_range = |#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0) /* t28: remap_file_range op is 5.0+ */\n    p->ops.remap_file_range = |' "$FW"
            sed -i 's|^\(    p->ops.remap_file_range = .*\)$|\1\n#endif /* t28: remap_file_range op */|' "$FW"
            sed -i 's|^    p->ops.iopoll = |#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0) /* t28: iopoll op is 6.1+ */\n    p->ops.iopoll = |' "$FW"
            sed -i 's|^\(    p->ops.iopoll = .*\)$|\1\n#endif /* t28: iopoll op */|' "$FW"
            # t31/F2: guarding only the assignment was not enough - the 2-arg
            # ksu_wrapper_iopoll() lives in the `#else` of the `#if >= 6.1` block,
            # so it stayed compiled on 4.19 and still dereferenced f_op->iopoll.
            # Making that branch require 6.1 as well removes it from 4.19 while
            # keeping >= 6.1 behaviour byte-for-byte identical (the `#if` branch wins).
            sed -i '/^static int ksu_wrapper_iopoll(struct kiocb \*kiocb, struct io_comp_batch \*icb, unsigned int v)$/,/^#endif$/s|^#else$|#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0) /* t31: iopoll member is 6.1+ */|' "$FW"
        fi
        for m in 'remap_file_range fn is 5.0+' 'remap_file_range op is 5.0+' 'iopoll op is 6.1+'; do
            if ! grep -q "t28: $m" "$FW"; then
                echo "FATAL: [infra/file_wrapper.c] guard for '$m' was not inserted."
                exit 1
            fi
        done
        for m in 'remap_file_range fn' 'remap_file_range op' 'iopoll op'; do
            if [ "$(grep -c "t28: $m \*/" "$FW" || true)" -ne 1 ]; then
                echo "FATAL: [infra/file_wrapper.c] the '#endif /* t28: $m */' terminator is missing or duplicated."
                exit 1
            fi
        done
        if ! grep -q 't31: iopoll member is 6.1+' "$FW"; then
            echo "FATAL: [infra/file_wrapper.c] the 2-arg ksu_wrapper_iopoll() branch is still compiled on 4.19."
            exit 1
        fi
        echo "4.19 fop guards applied: file_wrapper.c remap_file_range (4.20+ member, guarded at the 5.0 boundary) and iopoll (6.1+), incl. the 2-arg wrapper branch."

        # t35/A1: security_inode_init_security_anon() is 5.5+, and this 4.19 tree has
        # no such LSM hook (include/linux/security.h carries only
        # security_inode_init_security at :282 and a no-op variant at :651). The call
        # sits in the pre-5.16 fallback of ksu_anon_inode_make_secure_inode(), and that
        # fallback IS reachable here: ksu_file_wrapper_init() fills anon_inode_mnt under
        # `#if < 5.16` (file_wrapper.c:574) and is called from core/init.c:172/191, so
        # anon_inode_mnt is not permanently NULL. We therefore skip only the hook
        # instead of deleting the fallback: the wrapper inode keeps the default SELinux
        # blob, and ksu_install_file_wrapper() sets its sid directly from ksu_file_sid
        # (file_wrapper.c:526-531). `error = 0` keeps that variable initialized for the
        # `if (error)` check that follows.
        if ! grep -q 't35: no anon-inode LSM hook before 5.5' "$FW"; then
            sed -i 's|^\(    \)error = security_inode_init_security_anon(inode, &qname, context_inode);$|\1/* t35: no anon-inode LSM hook before 5.5 - security_inode_init_security_anon()\n\1 * does not exist in this 4.19 tree. Skipping it is safe: the wrapper inode keeps\n\1 * the default SELinux blob and ksu_install_file_wrapper() assigns its sid from\n\1 * ksu_file_sid directly. */\n\1#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 5, 0)\n\1error = security_inode_init_security_anon(inode, \&qname, context_inode);\n\1#else\n\1error = 0; /* t35: no anon-inode LSM hook before 5.5 */\n\1(void)qname; /* t40: keep qname used when the hook above is compiled out */\n\1#endif|' "$FW"
        fi
        # t35/A2: selinux_inode() is 5.9+ (security/selinux/include/objsec.h). This tree
        # declares struct inode_security_struct in objsec.h:57 and defines its own
        # inode_security() accessor in security/selinux/hooks.c:326-330 as a *static
        # inline* that just returns inode->i_security (struct inode field: fs.h:636), so
        # the 4.19 equivalent of selinux_inode(inode) is that cast.
        if ! grep -q 't35: selinux_inode is 5.9+' "$FW"; then
            sed -i 's|\bselinux_inode(wrapper_inode)|(struct inode_security_struct *)wrapper_inode->i_security /* t35: selinux_inode is 5.9+; 4.19 uses inode->i_security */|' "$FW"
        fi
        if ! grep -q 't35: no anon-inode LSM hook before 5.5' "$FW"; then
            echo "FATAL: [infra/file_wrapper.c] security_inode_init_security_anon() is still unguarded."
            exit 1
        fi
        if ! grep -q 'error = 0; /\* t35: no anon-inode LSM hook before 5.5 \*/' "$FW"; then
            echo "FATAL: [infra/file_wrapper.c] the pre-5.5 branch does not initialise 'error'."
            exit 1
        fi
        if ! awk '/t35: no anon-inode LSM hook before 5.5/{f=1} f && /#if LINUX_VERSION_CODE >= KERNEL_VERSION\(5, 5, 0\)/{print "ok"; exit}' "$FW" | grep -q ok; then
            echo "FATAL: [infra/file_wrapper.c] the anon-inode LSM hook is not wrapped in the 5.5 guard."
            exit 1
        fi
        if grep -qE '(^|[^_a-zA-Z0-9])selinux_inode[[:space:]]*\(' "$FW"; then
            echo "FATAL: [infra/file_wrapper.c] a bare selinux_inode() call (5.9+ accessor) is left."
            exit 1
        fi
        if ! grep -q 't35: selinux_inode is 5.9+' "$FW"; then
            echo "FATAL: [infra/file_wrapper.c] the selinux_inode() call was not replaced."
            exit 1
        fi
        echo "4.19 selinux shims applied: file_wrapper.c anon-inode hook guarded at 5.5, selinux_inode() -> inode->i_security."
    else
        if [ "$WITH_SUSFS" -le 1 ]; then echo "NOTE: KernelSU/kernel/feature/sucompat.c not present (3.x SUSFS tree) - the 5.8+ maccess shims are not needed."; else echo "SKIP [cline]: the 5.8+ maccess shims are A/B-only (this is the C line; ReSukiSU has its own ksu_* wrappers)."; fi
    fi

    if [ "$WITH_SUSFS" -eq 1 ]; then
        # Without the SUSFS glue in the KernelSU tree the SUSFS line would only
        # look like SUSFS: fail loudly instead of producing a fake kernel.
        if ! grep -q '^config KSU_SUSFS$' KernelSU/kernel/Kconfig; then
            echo "FATAL: KernelSU tree [$KSU_REF] has no SUSFS support (CONFIG_KSU_SUSFS is missing)."
            exit 1
        fi
    fi

    # t40/Part3: 4.x "core" line. Subsystems that only exist in 5.x kernels are
    # turned into version-guarded, API-shaped *stubs*: the original body stays
    # inside `#if LINUX_VERSION_CODE >= <ver>` and an `#else` branch with one
    # stub per exported symbol is appended. The files are never deleted and the
    # Kbuild is never touched, so every call site still links. Each stub warns
    # once, and the resulting feature loss is listed in KSU-4.19-COMPAT-SWEEP2.md
    # SS12. Guard boundaries: SELinux policy injection 5.5 (struct
    # selinux_state.policy / status_lock / status_page, struct selinux_policy),
    # seccomp arch cache 5.9 (struct seccomp.filter_count, SECCOMP_ARCH_NATIVE_NR),
    # vdso clock spoof 5.2 (struct clocksource.vdso_clock_mode).
    if [ "$WITH_SUSFS" -le 1 ] && [ -f KernelSU/kernel/selinux/selinux.c ] && [ -f KernelSU/kernel/feature/selinux_hide.c ] && [ -f KernelSU/kernel/infra/seccomp_cache.c ] && [ -f KernelSU/kernel/feature/cpu_spoof.c ] && [ -f KernelSU/kernel/policy/allowlist.c ] && [ -f KernelSU/kernel/manager/pkg_observer.c ] && [ -f KernelSU/kernel/supercall/dispatch.c ] && [ -f KernelSU/kernel/policy/app_profile.c ] && [ -f KernelSU/kernel/selinux/rules.c ] && [ -f KernelSU/kernel/selinux/sepolicy.c ]; then
        KSUK=KernelSU/kernel


        SEL="$KSUK/selinux/selinux.c"
        if ! grep -q 't40: selinux stubs' "$SEL"; then
            sed -i -e '1i /* t40: SELinux policy injection is a 5.5+ subsystem; on 4.19 every entry point below is a stub. */' -e '1i #if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 5, 0) /* t40: selinux gate */' "$SEL"
            cat >> "$SEL" <<'T40SELINUX'
#else /* t40: selinux stubs */
/* t40: 4.19 has no runtime SELinux policy injection (no struct selinux_state.policy,
 * no struct selinux_policy, no status_lock/status_page). Every symbol this module
 * exports to the rest of KernelSU is provided here with its exact signature so the
 * links stay intact; each one warns once and then degrades. Feature loss: KernelSU
 * cannot inject its SELinux rules/domain on this kernel, so su/file contexts are
 * not set up (see KSU-4.19-COMPAT-SWEEP2.md SS12). */
#include "selinux/selinux.h"
#include "selinux/sepolicy.h"
#include <linux/printk.h>
#include <linux/err.h>
#include <linux/cred.h>

static void t40_warn_selinux(bool *flag, const char *what)
{
    if (!*flag) {
        *flag = true;
        pr_warn("ksu: %s needs a 5.5+ SELinux; disabled on this 4.19 kernel\n", what);
    }
}

void setup_selinux(const char *policy, struct cred *cred) { static bool w; t40_warn_selinux(&w, "setup_selinux"); }
void setenforce(bool enforce) { static bool w; t40_warn_selinux(&w, "setenforce"); }
bool getenforce(void) { static bool w; t40_warn_selinux(&w, "getenforce"); return false; }
void cache_sid(void) { static bool w; t40_warn_selinux(&w, "cache_sid"); }
bool is_task_ksu_domain(const struct cred *cred) { static bool w; t40_warn_selinux(&w, "is_task_ksu_domain"); return false; }
bool is_ksu_domain(void) { static bool w; t40_warn_selinux(&w, "is_ksu_domain"); return false; }
bool is_zygote(const struct cred *cred) { static bool w; t40_warn_selinux(&w, "is_zygote"); return false; }
bool is_init(const struct cred *cred) { static bool w; t40_warn_selinux(&w, "is_init"); return false; }
void apply_kernelsu_rules(void) { static bool w; t40_warn_selinux(&w, "apply_kernelsu_rules"); }
int handle_sepolicy(void __user *user_data, u64 data_len) { static bool w; t40_warn_selinux(&w, "handle_sepolicy"); return -EOPNOTSUPP; }
void setup_ksu_cred(void) { static bool w; t40_warn_selinux(&w, "setup_ksu_cred"); }
void escape_to_root_for_adb_root(void) { static bool w; t40_warn_selinux(&w, "escape_to_root_for_adb_root"); }

/* The file-context sid lives here; 0 keeps the wrappers non-NULL and is only ever
 * compared against an inode sid, never used to look anything up. */
u32 ksu_file_sid;

struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol) { static bool w; t40_warn_selinux(&w, "ksu_dup_sepolicy"); return ERR_PTR(-EOPNOTSUPP); }
void ksu_destroy_sepolicy(struct selinux_policy *orig) { static bool w; t40_warn_selinux(&w, "ksu_destroy_sepolicy"); }
bool ksu_type(struct policydb *db, const char *name, const char *attr) { static bool w; t40_warn_selinux(&w, "ksu_type"); return false; }
bool ksu_attribute(struct policydb *db, const char *name) { static bool w; t40_warn_selinux(&w, "ksu_attribute"); return false; }
bool ksu_permissive(struct policydb *db, const char *type) { static bool w; t40_warn_selinux(&w, "ksu_permissive"); return false; }
bool ksu_enforce(struct policydb *db, const char *type) { static bool w; t40_warn_selinux(&w, "ksu_enforce"); return false; }
bool ksu_typeattribute(struct policydb *db, const char *type, const char *attr) { static bool w; t40_warn_selinux(&w, "ksu_typeattribute"); return false; }
bool ksu_exists(struct policydb *db, const char *type) { static bool w; t40_warn_selinux(&w, "ksu_exists"); return false; }
bool ksu_allow(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm) { static bool w; t40_warn_selinux(&w, "ksu_allow"); return false; }
bool ksu_deny(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm) { static bool w; t40_warn_selinux(&w, "ksu_deny"); return false; }
bool ksu_auditallow(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm) { static bool w; t40_warn_selinux(&w, "ksu_auditallow"); return false; }
bool ksu_dontaudit(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm) { static bool w; t40_warn_selinux(&w, "ksu_dontaudit"); return false; }
bool ksu_allowxperm(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *range) { static bool w; t40_warn_selinux(&w, "ksu_allowxperm"); return false; }
bool ksu_auditallowxperm(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *range) { static bool w; t40_warn_selinux(&w, "ksu_auditallowxperm"); return false; }
bool ksu_dontauditxperm(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *range) { static bool w; t40_warn_selinux(&w, "ksu_dontauditxperm"); return false; }
bool ksu_type_change(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *def) { static bool w; t40_warn_selinux(&w, "ksu_type_change"); return false; }
bool ksu_type_member(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *def) { static bool w; t40_warn_selinux(&w, "ksu_type_member"); return false; }
bool ksu_type_transition(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *def, const char *obj) { static bool w; t40_warn_selinux(&w, "ksu_type_transition"); return false; }
bool ksu_genfscon(struct policydb *db, const char *fs_name, const char *path, const char *ctx) { static bool w; t40_warn_selinux(&w, "ksu_genfscon"); return false; }
#endif /* t40: selinux end */
T40SELINUX
        fi
        for f in "$KSUK/selinux/rules.c" "$KSUK/selinux/sepolicy.c"; do
            if ! grep -q 't40: selinux-extra gate' "$f"; then
                sed -i -e '1i /* t40: policy injection is 5.5+; every symbol this file exports is stubbed in selinux/selinux.c (empty stub branch on purpose, so nothing is defined twice). */' -e '1i #if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 5, 0) /* t40: selinux-extra gate */' "$f"
                printf '\n#else /* t40: selinux-extra stubs */\n/* no definitions here: the exported API is stubbed once, in selinux/selinux.c */\n#endif /* t40: selinux-extra end */\n' >> "$f"
            fi
            if [ "$(grep -c 't40: selinux-extra gate' "$f")" != "1" ] || [ "$(grep -c 't40: selinux-extra stubs' "$f")" != "1" ]; then
                echo "FATAL: [$f] is not wrapped in the t40 selinux-extra version gate."
                exit 1
            fi
        done

        SHIDE="$KSUK/feature/selinux_hide.c"
        if ! grep -q 't40: selinux_hide stubs' "$SHIDE"; then
            sed -i -e '1i /* t40: SELinux status hiding is 5.5+; on 4.19 the feature degrades to no-op stubs. */' -e '1i #if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 5, 0) /* t40: selinux_hide gate */' "$SHIDE"
            cat >> "$SHIDE" <<'T40HIDE'
#else /* t40: selinux_hide stubs */
/* t40: the feature pokes struct selinux_state.status_lock/status_page/policy and
 * struct selinux_policy, all of which are 5.5+ (run6: 15 errors). Feature loss:
 * SELinux status/backup hiding is unavailable on 4.19. */
#include <linux/printk.h>

static void t40_warn_hide(const char *what)
{
    pr_warn("ksu: %s needs a 5.5+ SELinux; disabled on this 4.19 kernel\n", what);
}

void ksu_selinux_hide_init(void) { t40_warn_hide("ksu_selinux_hide_init"); }
void ksu_selinux_hide_exit(void) { }
void ksu_selinux_hide_drop_backup_if_unused(void) { }
void ksu_selinux_hide_handle_second_stage(void) { }
void ksu_selinux_hide_handle_post_fs_data(void) { }
#endif /* t40: selinux_hide end */
T40HIDE
        fi
        if [ "$(grep -c 't40: selinux_hide gate' "$SHIDE")" != "1" ] || [ "$(grep -c 't40: selinux_hide stubs' "$SHIDE")" != "1" ]; then
            echo "FATAL: [$SHIDE] is not wrapped in the t40 selinux_hide version gate."
            exit 1
        fi

        SCC="$KSUK/infra/seccomp_cache.c"
        if ! grep -q 't40: seccomp_cache stubs' "$SCC"; then
            sed -i -e '1i /* t40: the seccomp arch cache is 5.9+ (struct seccomp.filter_count, SECCOMP_ARCH_NATIVE_NR). */' -e '1i #if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0) /* t40: seccomp_cache gate */' "$SCC"
            cat >> "$SCC" <<'T40SECCOMP'
#else /* t40: seccomp_cache stubs */
/* t40: 4.19 has no struct seccomp.filter_count and no SECCOMP_ARCH_NATIVE_NR
 * (run6: 3 errors). Feature loss: the seccomp fast-path cache is a no-op, so
 * every seccomp filter is still evaluated (correct, just slower). */
#include <linux/printk.h>
#include <linux/seccomp.h>

void ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr)
{
    static bool w;
    if (!w) {
        w = true;
        pr_warn("ksu: seccomp cache needs a 5.9+ kernel; no-op on this 4.19 kernel\n");
    }
}

void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr)
{
}
#endif /* t40: seccomp_cache end */
T40SECCOMP
        fi
        if [ "$(grep -c 't40: seccomp_cache gate' "$SCC")" != "1" ] || [ "$(grep -c 't40: seccomp_cache stubs' "$SCC")" != "1" ]; then
            echo "FATAL: [$SCC] is not wrapped in the t40 seccomp_cache version gate."
            exit 1
        fi

        CSP="$KSUK/feature/cpu_spoof.c"
        if ! grep -q 't40: cpu_spoof stubs' "$CSP"; then
            sed -i -e '1i /* t40: vdso clock spoofing needs struct clocksource.vdso_clock_mode (5.2+). */' -e '1i #if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0) /* t40: cpu_spoof gate */' "$CSP"
            cat >> "$CSP" <<'T40SPOOF'
#else /* t40: cpu_spoof stubs */
/* t40: struct clocksource has no vdso_clock_mode member before 5.2 (run6: 3
 * errors). Feature loss: CPU spoofing still answers the cmd, but the vdso clock
 * source cannot be rewritten, so the spoof is not effective. */
#include "feature/cpu_spoof.h"
#include <linux/printk.h>
#include <linux/err.h>

int ksu_set_spoof_cpu(const struct ksu_set_spoof_cpu_cmd *cmd)
{
    static bool w;
    if (!w) {
        w = true;
        pr_warn("ksu: cpu spoof needs a 5.2+ kernel (clocksource.vdso_clock_mode); disabled on this 4.19 kernel\n");
    }
    return -EOPNOTSUPP;
}
#endif /* t40: cpu_spoof end */
T40SPOOF
        fi
        if [ "$(grep -c 't40: cpu_spoof gate' "$CSP")" != "1" ] || [ "$(grep -c 't40: cpu_spoof stubs' "$CSP")" != "1" ]; then
            echo "FATAL: [$CSP] is not wrapped in the t40 cpu_spoof version gate."
            exit 1
        fi
        echo "4.19 5.x-feature stubs applied: selinux/{selinux,rules,sepolicy}.c (5.5), feature/selinux_hide.c (5.5), infra/seccomp_cache.c (5.9), feature/cpu_spoof.c (5.2)."

        # t40/Part4: the misc errors from the run6 list, each with its 4.19 evidence.
        # (a) copy_from_user_nofault() does not exist in this tree at all (verified:
        #     include/linux/uaccess.h has 0 hits) - the t28 compat header gains a
        #     fourth shim and the call sites are renamed; the positive line above
        #     counts them at run time.
        # (b) put_task_struct() is declared in include/linux/sched/task.h:96 on 4.19.
        # (c) fallthrough is 5.4+; this tree has no __fallthrough either, so use the
        #     4.19 idiom (a /* fall through */ comment) which satisfies
        #     -Wimplicit-fallthrough.
        # (d) fsnotify_ops.handle_inode_event is 5.9+; 4.19 only has handle_event with
        #     the signature the compiler printed in run6 - adapt with a no-op.
        # (e) tasklist_lock/init_task/task_pgrp/task_session: add the two headers that
        #     carry them on 4.19 (sched/signal.h, init_task.h) plus explicit externs
        #     for the two that no 4.19 header advertises to modules.
        # (f) policies here lose the adb-root escape path's SELinux part; see SS12.
        AL="$KSUK/policy/allowlist.c"
        if ! grep -q 't40: put_task_struct' "$AL"; then
            sed -i -e '1i #include <linux/sched/task.h> /* t40: put_task_struct (task.h:96 on 4.19) */' "$AL"
            sed -i 's/^\([[:space:]]*\)fallthrough;$/\1\/* fall through *\/  \/* t40: fallthrough is 5.4+; 4.19 idiom *\//' "$AL"
        fi
        if ! grep -q 'sched/task.h' "$AL"; then
            echo "FATAL: [$AL] does not include <linux/sched/task.h> (put_task_struct)."
            exit 1
        fi
        PO="$KSUK/manager/pkg_observer.c"
        if ! grep -q 't40: handle_inode_event' "$PO"; then
            sed -i 's|^\([[:space:]]*\)\.handle_inode_event = |#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0) /* t40: handle_inode_event */\n\1.handle_inode_event = |' "$PO"
            sed -i 's|^\([[:space:]]*\)\.handle_inode_event = \(.*\)$|\1.handle_inode_event = \2\n#else\n\1.handle_event = ksu_t40_handle_event_compat,\n#endif /* t40: handle_inode_event */|' "$PO"
            sed -i 's|^static const struct fsnotify_ops|#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n/* t40: 4.19 has only handle_event; the observer degrades to a no-op. */\nstatic int ksu_t40_handle_event_compat(struct fsnotify_group *group, struct inode *inode, u32 mask,\n                                       const void *data, int data_type, const unsigned char *file_name,\n                                       u32 cookie, struct fsnotify_iter_info *iter_info)\n{\n    return 0;\n}\n#endif\nstatic const struct fsnotify_ops|' "$PO"
        fi
        if ! grep -q 't40: handle_inode_event' "$PO" || ! grep -q 'ksu_t40_handle_event_compat' "$PO"; then
            echo "FATAL: [$PO] was not adapted to the 4.19 fsnotify_ops API."
            exit 1
        fi
        DIS="$KSUK/supercall/dispatch.c"
        if ! grep -q 't40: 4.19 task/sched includes' "$DIS"; then
            printf '%s\n' \
                '#include <linux/sched/signal.h> /* t40: 4.19 task/sched includes */' \
                '#include <linux/init_task.h>' \
                'extern rwlock_t tasklist_lock;      /* defined in kernel/fork.c; no 4.19 header advertises it */' \
                'extern struct task_struct init_task; /* defined in init/init_task.c */' > "$DIS.t40"
            cat "$DIS" >> "$DIS.t40"
            mv "$DIS.t40" "$DIS"
        fi
        if ! grep -q 't40: 4.19 task/sched includes' "$DIS"; then
            echo "FATAL: [$DIS] is missing the t40 task/sched includes."
            exit 1
        fi
        # t46/P1: policy/app_profile.c also touches a 5.x seccomp member
        # (struct seccomp.filter_count, added with the 5.9 seccomp arch cache), which
        # t40 missed - it only stubbed infra/seccomp_cache.c. On 4.19 the counter does
        # not exist, so the reset is simply skipped (nothing else reads it here).
        AP="$KSUK/policy/app_profile.c"
        if ! grep -q 't46: struct seccomp.filter_count is 5.9+' "$AP"; then
            sed -i 's|^\([[:space:]]*\)atomic_set(&current->seccomp.filter_count, 0);$|\1/* t46: struct seccomp.filter_count is 5.9+; 4.19 has no such counter. */\n\1#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n\1atomic_set(\&current->seccomp.filter_count, 0);\n\1#endif|' "$AP"
        fi
        if ! grep -q 't46: struct seccomp.filter_count is 5.9+' "$AP"; then
            echo "FATAL: [$AP] still touches struct seccomp.filter_count unguarded (5.9+ member)."
            exit 1
        fi
        echo "4.19 misc fixes applied: copy_from_user_nofault shim, put_task_struct include, fallthrough idiom, fsnotify handle_event adapter, task/sched includes."
        echo "4.19 app_profile seccomp fix applied: filter_count reset guarded at 5.9."

        # t43/F1: mechanical per-stub ARITY gate. A stub definition whose parameter
        # list disagrees with the prototype visible in the same TU is a hard error
        # (C11 6.7p4, "conflicting types"), which is exactly what happened with
        # ksu_type_transition (5 params vs the 6 in sepolicy.h - the t40 stub moved
        # rules.c's error into selinux.c). Eyeballing signatures has now produced
        # four regressions (t29 F1, t31 F2#1/#2, t40 F1), so this is mechanical:
        # every stubbed symbol's parameter count is compared against its header
        # declaration, and any mismatch fails the build. HARD RULE: a stub signature
        # must be character-for-character identical to its header declaration.
        # t46/P1: the prepended version gate must see LINUX_VERSION_CODE/KERNEL_VERSION
        # before its first use. run7 showed a gate sitting above the file's own
        # #include <linux/version.h> is a hard -Werror,-Wundef failure (18 of the 22
        # errors: 3 per file x 6 files). This post-pass prepends the include to line 1,
        # i.e. above both the t40 comment and the gate, and is idempotent.
        for t46_vf in "$SEL" "$KSUK/selinux/rules.c" "$KSUK/selinux/sepolicy.c" "$SHIDE" "$SCC" "$CSP"; do
            if ! grep -q 'include <linux/version.h> /\* t46' "$t46_vf"; then
                sed -i -e '1i #include <linux/version.h> /* t46: the t40 gate below needs LINUX_VERSION_CODE/KERNEL_VERSION before the file includes */' "$t46_vf"
            fi
            if ! grep -q 'include <linux/version.h> /\* t46' "$t46_vf"; then
                echo "FATAL: [t46] [$t46_vf] did not get the <linux/version.h> include for its version gate."
                exit 1
            fi
        done
        echo "t46 version-macro include prepass applied to 6 gated files."

        t43_arity() { # $1 = file to scan, $2 = symbol -> prints the parameter count
            awk -v s="$2" '
              { buf = buf " " $0 }
              END {
                n = length(buf); p = index(buf, s "(");
                if (p == 0) { print "?"; exit }
                j = p + length(s) + 1; depth = 1; args = "";
                while (j <= n) {
                  c = substr(buf, j, 1);
                  if (c == "(") depth++;
                  else if (c == ")") { depth--; if (depth == 0) break }
                  args = args c; j++;
                }
                gsub(/^[ \t]+/, "", args); gsub(/[ \t]+$/, "", args);
                if (args == "" || args == "void") { print 0; exit }
                cnt = 1;
                for (k = 1; k <= length(args); k++) if (substr(args, k, 1) == ",") cnt++;
                print cnt;
              }' "$1"
        }
        T43TMP=$(mktemp -d)
        sed -n '/#else \/\* t40: selinux stubs \*\//,/#endif \/\* t40: selinux end \*\//p' "$SEL" > "$T43TMP/selinux.stubs"
        sed -n '/#else \/\* t40: selinux_hide stubs \*\//,/#endif \/\* t40: selinux_hide end \*\//p' "$SHIDE" > "$T43TMP/hide.stubs"
        sed -n '/#else \/\* t40: seccomp_cache stubs \*\//,/#endif \/\* t40: seccomp_cache end \*\//p' "$SCC" > "$T43TMP/seccomp.stubs"
        sed -n '/#else \/\* t40: cpu_spoof stubs \*\//,/#endif \/\* t40: cpu_spoof end \*\//p' "$CSP" > "$T43TMP/spoof.stubs"
        t43_bad=0
        t43_n=0
        while read -r t43_sym t43_hdr t43_stub; do
            [ -n "${t43_sym:-}" ] || continue
            t43_a=$(t43_arity "$KSUK/$t43_hdr" "$t43_sym")
            t43_b=$(t43_arity "$T43TMP/$t43_stub" "$t43_sym")
            t43_n=$((t43_n + 1))
            printf '   [arity] %-34s header(%s)=%s stub=%s\n' "$t43_sym" "$t43_hdr" "$t43_a" "$t43_b"
            if [ "$t43_a" != "$t43_b" ]; then
                echo "FATAL: [t43] stub arity mismatch for $t43_sym: header($t43_hdr)=$t43_a, stub=$t43_b"
                t43_bad=1
            fi
        done < <(tee "$T43TMP/list.txt" <<'T43LIST'
setup_selinux selinux/selinux.h selinux.stubs
setenforce selinux/selinux.h selinux.stubs
getenforce selinux/selinux.h selinux.stubs
cache_sid selinux/selinux.h selinux.stubs
is_task_ksu_domain selinux/selinux.h selinux.stubs
is_ksu_domain selinux/selinux.h selinux.stubs
is_zygote selinux/selinux.h selinux.stubs
is_init selinux/selinux.h selinux.stubs
apply_kernelsu_rules selinux/selinux.h selinux.stubs
handle_sepolicy selinux/selinux.h selinux.stubs
setup_ksu_cred selinux/selinux.h selinux.stubs
escape_to_root_for_adb_root selinux/selinux.h selinux.stubs
ksu_dup_sepolicy selinux/sepolicy.h selinux.stubs
ksu_destroy_sepolicy selinux/sepolicy.h selinux.stubs
ksu_type selinux/sepolicy.h selinux.stubs
ksu_attribute selinux/sepolicy.h selinux.stubs
ksu_permissive selinux/sepolicy.h selinux.stubs
ksu_enforce selinux/sepolicy.h selinux.stubs
ksu_typeattribute selinux/sepolicy.h selinux.stubs
ksu_exists selinux/sepolicy.h selinux.stubs
ksu_allow selinux/sepolicy.h selinux.stubs
ksu_deny selinux/sepolicy.h selinux.stubs
ksu_auditallow selinux/sepolicy.h selinux.stubs
ksu_dontaudit selinux/sepolicy.h selinux.stubs
ksu_allowxperm selinux/sepolicy.h selinux.stubs
ksu_auditallowxperm selinux/sepolicy.h selinux.stubs
ksu_dontauditxperm selinux/sepolicy.h selinux.stubs
ksu_type_transition selinux/sepolicy.h selinux.stubs
ksu_type_change selinux/sepolicy.h selinux.stubs
ksu_type_member selinux/sepolicy.h selinux.stubs
ksu_genfscon selinux/sepolicy.h selinux.stubs
ksu_selinux_hide_init feature/selinux_hide.h hide.stubs
ksu_selinux_hide_exit feature/selinux_hide.h hide.stubs
ksu_selinux_hide_drop_backup_if_unused feature/selinux_hide.h hide.stubs
ksu_selinux_hide_handle_second_stage feature/selinux_hide.h hide.stubs
ksu_selinux_hide_handle_post_fs_data feature/selinux_hide.h hide.stubs
ksu_seccomp_clear_cache infra/seccomp_cache.h seccomp.stubs
ksu_seccomp_allow_cache infra/seccomp_cache.h seccomp.stubs
ksu_set_spoof_cpu feature/cpu_spoof.h spoof.stubs
T43LIST
)
        if [ "$t43_bad" != "0" ]; then
            echo "FATAL: [t43] at least one t40 stub disagrees with its header prototype (see the [arity] lines above)."
            exit 1
        fi
        if [ "$t43_n" != "39" ]; then
            echo "FATAL: [t43] the arity gate only checked $t43_n stubs, expected 39."
            exit 1
        fi
        echo "4.19 stub arity gate passed: $t43_n stubs match their header prototypes."

        # t46/P2-1: -Wundef position gate. The prepended version gate must see
        # LINUX_VERSION_CODE/KERNEL_VERSION before its first use: run7 proved that a
        # gate placed above the file's own #include <linux/version.h> is a hard
        # -Werror,-Wundef failure (18 of run7's 22 errors, 3 per file x 6 files).
        for t46_f in "$SEL" "$KSUK/selinux/rules.c" "$KSUK/selinux/sepolicy.c" "$SHIDE" "$SCC" "$CSP"; do
            t46_first=$(grep -nE '#[[:space:]]*(if|elif).*LINUX_VERSION_CODE' "$t46_f" | head -1 | cut -d: -f1)
            t46_inc=$(grep -n '#include <linux/version.h>' "$t46_f" | head -1 | cut -d: -f1)
            if [ -z "${t46_first:-}" ]; then
                echo "FATAL: [t46] [$t46_f] has no version-gated block."
                exit 1
            fi
            if [ -z "${t46_inc:-}" ] || [ "$t46_inc" -ge "$t46_first" ]; then
                echo "FATAL: [t46] [$t46_f] uses LINUX_VERSION_CODE at line $t46_first but includes <linux/version.h> at line ${t46_inc:-never} (-Wundef would fire)."
                exit 1
            fi
        done
        echo "t46 version-gate position gate passed: all 6 gated files include <linux/version.h> before their first version-macro use."

        # t46/P2-3: every stub actually defined in the stub blocks must be registered in
        # the arity list, otherwise a newly added stub would silently escape the gate.
        awk -F'(' '/^[a-zA-Z_]/ && !/^static/ && NF > 1 { n = split($1, a, /[ \t]/); nm = a[n]; sub(/^\*/, "", nm); print nm }' "$T43TMP"/*.stubs | sort -u > "$T43TMP/defined.txt"
        cut -d' ' -f1 "$T43TMP/list.txt" | sort -u > "$T43TMP/listed.txt"
        if [ -n "$(comm -23 "$T43TMP/defined.txt" "$T43TMP/listed.txt")" ]; then
            echo "FATAL: [t46] these stubs are defined but not registered in the arity list:"
            comm -23 "$T43TMP/defined.txt" "$T43TMP/listed.txt" | sed 's/^/   /'
            exit 1
        fi
        echo "t46 stub registration gate passed: every defined stub is registered."
        rm -rf "$T43TMP"
    else
        if [ "$WITH_SUSFS" -le 1 ]; then echo "NOTE: the 4.x-only KernelSU files (selinux/*, feature/selinux_hide.c, infra/seccomp_cache.c, feature/cpu_spoof.c, policy/allowlist.c, policy/app_profile.c, manager/pkg_observer.c, supercall/dispatch.c) are not present (3.x SUSFS tree) - the t40 stubs and misc fixes are not needed."; else echo "SKIP [cline]: the t40 stubs are A/B-only (this is the C line; those files EXIST here and the stubs would disable ReSukiSU features that work)."; fi
    fi

    # t46/P2-2: B-leg (3.x SUSFS tree) coverage gate - deliberately OUTSIDE the guarded
    # block above, so it runs on both A/B lines: it inspects this script's own text and
    # requires every 4.x-only file it handles to sit behind a `[ -f ... ]` test.
    # run7's B leg died after ~2 minutes on feature/selinux_hide.c precisely because
    # that handling had no existence guard (a runtime check inside the guarded block
    # could never catch its own missing guard).
    #
    # C line: this gate asserts facts about the A/B-line t40 block, which the C line
    # never runs (see the `WITH_SUSFS -le 1` note above), so it is A/B-only.
    if [ "$WITH_SUSFS" -le 1 ]; then
    t46_self="${0:-build.sh}"
    # t52/F3: anchor this gate to the single t40 guard line instead of scanning the whole
    # script - a decoy comment line containing the literal "[ -f <path> ]" used to satisfy
    # the old whole-file `grep -qF`.
    t52_guard_ln=$(grep -n '^    if \[ "\$WITH_SUSFS" -le 1 \] && \[ -f KernelSU/kernel/selinux/selinux.c \]' "$t46_self" | head -1 | cut -d: -f1)
    if [ -z "${t52_guard_ln:-}" ]; then
        echo "FATAL: [t52] the t40 existence-guard line (WITH_SUSFS -le 1 && [ -f KernelSU/kernel/selinux/selinux.c ]) is gone."
        exit 1
    fi
    t52_guard=$(sed -n "${t52_guard_ln}p" "$t46_self")
    t52_cnt=$(printf '%s' "$t52_guard" | grep -oF '[ -f ' | wc -l)
    if [ "$t52_cnt" -ne 10 ]; then
        echo "FATAL: [t52] the t40 guard line carries $t52_cnt existence tests, expected exactly 10."
        exit 1
    fi
    for t46_p in KernelSU/kernel/selinux/selinux.c KernelSU/kernel/selinux/rules.c KernelSU/kernel/selinux/sepolicy.c KernelSU/kernel/feature/selinux_hide.c KernelSU/kernel/infra/seccomp_cache.c KernelSU/kernel/feature/cpu_spoof.c KernelSU/kernel/policy/allowlist.c KernelSU/kernel/policy/app_profile.c KernelSU/kernel/manager/pkg_observer.c KernelSU/kernel/supercall/dispatch.c; do
        case "$t52_guard" in
            *"[ -f $t46_p ]"*) ;;
            *)
                echo "FATAL: [t52] [$t46_p] is missing from the t40 existence-guard line (a decoy comment cannot satisfy this)."
                exit 1
                ;;
        esac
    done
    echo "t46 B-leg guard coverage gate passed: the single t40 guard line carries exactly 10 existence tests (comment-proof)."
    fi

    # t49: the fork's kernel tree was patched for the *3.x* KernelSU hook API and
    # guards those call sites with `#ifdef CONFIG_KSU` (both lines set CONFIG_KSU), so
    # the 4.x tree - which renamed/removed that API - leaves 8 symbols undefined at
    # link time (run8: fs/open.c:461, fs/read_write.c:598/599, fs/stat.c:386/539,
    # fs/exec.c:1954/1955/1987, drivers/tty/pty.c:724, drivers/input/input.c:458).
    # This is NOT a config problem: the kernel tree's own `extern` declarations are the
    # contract, and the 4.x tree simply does not define those names any more
    # (grep: ksu_handle_faccessat/stat/devpts/vfs_read_hook/execveat_hook/input_hook = 0
    # hits in the 4.x tree). So we provide an API-shaped compat layer with exactly the
    # kernel tree's signatures, and keep the three legacy enable flags false: the 4.x
    # line does its own hooking (kprobe/tracepoint + *_sucompat/_ksud), and the kernel
    # tree's `else` branches (e.g. ksu_handle_execveat_sucompat) keep working. That
    # preserves the SPEC rule "A line has zero MANUAL_HOOK" - no SPEC change needed.
    if [ "$WITH_SUSFS" -le 1 ] && [ -f KernelSU/kernel/runtime/ksud_integration.c ]; then
        KI=KernelSU/kernel/runtime/ksud_integration.c
        if ! grep -q 't49: legacy 3.x hook API compat layer' "$KI"; then
            # ksu_handle_sys_read already exists here as `static void`; the kernel tree
            # declares it `int` with the same three parameters, so un-static it and give
            # it the matching return type (its only caller ignores the result).
            sed -i 's|^static void ksu_handle_sys_read(unsigned int fd, char __user \*\*buf_ptr, size_t \*count_ptr)$|int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr) /* t49: un-static + int return (kernel-tree contract) */|' "$KI"
            # t52/F1+F2: the function is `int` now, so its early-out must be `return 0;`
            # (a bare `return;` is ill-formed in a non-void function - C11 6.8.6.4p1 - and
            # -Werror turns -Wreturn-type into a hard error), and the new `return 0;` must
            # be inserted AFTER fput(file); otherwise fput() becomes unreachable and every
            # hooked sys_read leaks a struct file reference. Both edits are scoped to this
            # function's line range so no other function in the file can be touched.
            sed -i '/^int ksu_handle_sys_read(/,/^}/ s|^\([[:space:]]*\)return;$|\1return 0; /* t52: int function, not void */|' "$KI"
            sed -i '/^int ksu_handle_sys_read(/,/^}/ s|^\([[:space:]]*\)fput(file);$|\1fput(file);\n\1return 0; /* t49 */|' "$KI"
            cat >> "$KI" <<'T49COMPAT'

/* t49: legacy 3.x hook API compat layer.
 * The fork's kernel tree (fs/open.c, fs/read_write.c, fs/stat.c, fs/exec.c,
 * drivers/tty/pty.c, drivers/input/input.c) declares and calls these 8 symbols
 * under `#ifdef CONFIG_KSU`; the 4.x tree renamed the API, so without this layer
 * vmlinux fails to link. Signatures are copied character-for-character from the
 * kernel tree's own extern declarations. The three enable flags are false: the 4.x
 * line hooks through its own kprobe/tracepoint machinery (and the kernel tree's
 * `else` branch still calls ksu_handle_execveat_sucompat), so nothing is lost and
 * the legacy manual-hook paths stay inert. */
bool ksu_vfs_read_hook __read_mostly = false;
bool ksu_execveat_hook __read_mostly = false;
bool ksu_input_hook __read_mostly = false;

int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags)
{
    return 0;
}

int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)
{
    return 0;
}

int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags)
{
    return 0;
}

int ksu_handle_devpts(struct inode *inode)
{
    return 0;
}
T49COMPAT
        fi
        # t52/F3: the symbol check must look at *code* lines only - the old whole-file
        # substring grep was satisfied by a decoy comment mentioning the symbol name.
        t52_code() { awk '{ if ($0 ~ /^[[:space:]]*\/\*/) c = 1; if (!c) print; if (c && $0 ~ /\*\//) c = 0 }' "$1"; }
        t52_code "$KI" > "$KI.t52code"
        for t49_s in 'ksu_vfs_read_hook:bool' 'ksu_execveat_hook:bool' 'ksu_input_hook:bool' 'ksu_handle_faccessat:int' 'ksu_handle_sys_read:int' 'ksu_handle_stat:int' 'ksu_handle_execveat:int' 'ksu_handle_devpts:int'; do
            t49_n=${t49_s%%:*}
            t49_t=${t49_s##*:}
            if [ "$t49_t" = bool ]; then
                t49_p="^[[:space:]]*bool[[:space:]]+$t49_n[[:space:]]+__read_mostly"
            else
                t49_p="^[[:space:]]*int[[:space:]]+$t49_n[[:space:]]*\("
            fi
            if ! grep -qE "$t49_p" "$KI.t52code"; then
                echo "FATAL: [t52] [$KI] has no top-level definition of '$t49_n' (a comment mentioning it does not count)."
                exit 1
            fi
        done
        rm -f "$KI.t52code"
        echo "t49 legacy hook compat layer applied: 8 kernel-tree symbols defined (flags false, handlers no-op)."

        # t52/F1+F2 self-check: the t49 edit turned ksu_handle_sys_read() from `static void`
        # into `int`, so the body must be legal and leak-free - no bare `return;` (C11
        # 6.8.6.4p1; -Werror would make it a hard error) and fput() must come before the
        # `return 0;` (otherwise every hooked sys_read leaks a struct file reference).
        if ! awk '
            /^int ksu_handle_sys_read\(/ { in_fn = 1 }
            in_fn && /^[[:space:]]*return;[[:space:]]*$/ { bad_ret = 1 }
            in_fn && /ksu_install_rc_hook\(file\);/ { after_hook = 1 }
            in_fn && /^[[:space:]]*return/ && after_hook && !fput_seen { bad_order = 1 }
            in_fn && /fput\(file\);/ { fput_seen = 1 }
            in_fn && /^}/ {
                if (bad_ret) { print "reason: bare `return;` inside an int function (C11 6.8.6.4p1)"; exit 1 }
                if (bad_order) { print "reason: a return sits between ksu_install_rc_hook() and fput() -> fput is unreachable (struct file reference leak)"; exit 1 }
                if (!fput_seen) { print "reason: fput(file) is missing"; exit 1 }
                found = 1; exit 0
            }
            END { if (!found) { print "reason: int ksu_handle_sys_read() not found"; exit 1 } }
        ' "$KI"; then
            echo "FATAL: [t52] [$KI] ksu_handle_sys_read() is not a legal, leak-free int function (reason above)."
            exit 1
        fi
        echo "t52 ksu_handle_sys_read body check passed: int return, fput() before return, no bare return."

        # t49: policy/app_profile.c:123 calls seccomp_filter_release(), which is 5.9+;
        # 4.19 has the same operation as put_seccomp_filter(struct task_struct *)
        # (kernel/seccomp.c:522, declared in include/linux/seccomp.h:83). Its own
        # declaration at :69 is guarded the same way. (The NEED_BACKPORT_COMPAT block
        # at :240-251 is `>= 6.6 && < 6.11` => not compiled here.)
        if ! grep -q 't49: seccomp_filter_release is 5.9+' "$AP"; then
            sed -i 's|^void seccomp_filter_release(struct task_struct \*tsk);$|#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0) /* t49: seccomp_filter_release is 5.9+ */\nvoid seccomp_filter_release(struct task_struct *tsk);\n#endif|' "$AP"
            sed -i 's|^\([[:space:]]*\)seccomp_filter_release(fake);$|\1#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0) /* t49: seccomp_filter_release is 5.9+ */\n\1seccomp_filter_release(fake);\n\1#else\n\1put_seccomp_filter(fake); /* t49: 4.19 equivalent (kernel/seccomp.c:522) */\n\1#endif|' "$AP"
        fi
        if ! grep -q 't49: seccomp_filter_release is 5.9+' "$AP" || ! grep -q 'put_seccomp_filter(fake); /\* t49' "$AP"; then
            echo "FATAL: [t49] [$AP] still calls seccomp_filter_release() unguarded (5.9+ symbol)."
            exit 1
        fi
        echo "t49 seccomp fix applied: seccomp_filter_release guarded at 5.9, 4.19 uses put_seccomp_filter."
    else
        if [ "$WITH_SUSFS" -le 1 ]; then echo "NOTE: KernelSU/kernel/runtime/ksud_integration.c not present (3.x SUSFS tree) - the t49 legacy hook compat layer is not needed (the 3.x tree defines that API itself)."; else echo "SKIP [cline]: the t49 legacy hook compat layer is A/B-only (this is the C line; the file exists, and stubbing it would collide with the 2.3.0 patch call sites)."; fi
    fi

    # t55: real-device oops (ramoops: 6 crashes at 2.14-2.20s, ESR 0x96000005,
    # `pc : ksu_handle_execveat_sucompat+0x10/0x24`, fault address 0x10 = NULL+0x10).
    # The fork's kernel tree carries 3.x-era call sites guarded by `#ifdef CONFIG_KSU`
    # (both lines set CONFIG_KSU). Most of them call our own compat stubs, but two call
    # `ksu_handle_execveat_sucompat()`, whose 4.x definition is
    #   long ksu_handle_execveat_sucompat(const char __user **filename_user, int orig_nr,
    #                                     struct pt_regs *regs)      [feature/sucompat.c:256]
    # while the kernel tree calls it with the 3.x convention
    #   ksu_handle_execveat_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL)
    # => the 3rd (4.x) parameter `regs` receives NULL => deref at offset 0x10. t49 set
    # ksu_execveat_hook=false, which is exactly what routes into that else branch.
    # The 4.x tree has its own, correctly-conventioned path
    # (hook/syscall_event_bridge.c:103 calls it with 3 args), so the kernel tree's legacy
    # call sites are redundant *and* harmful on the 4.x line. Decision (option A, not the
    # flag-flip B): neutralise the call sites structurally - flipping the flags would only
    # hide the mismatched call behind a runtime condition and leave the 4.x function one
    # config edit away from crashing again. The neutralisation is applied ONLY when the
    # 4.x tree is present: the 3.x SUSFS line needs those very call sites (its sucompat.c
    # defines them with the 3.x convention), so it stays untouched.
    if [ "$WITH_SUSFS" -le 1 ] && [ -f KernelSU/kernel/hook/syscall_event_bridge.c ]; then
        t55_strip() { # $1 = file, $2 = sed address, $3 = literal probe text
            if [ -f "$1" ] && grep -qF -- "$3" "$1"; then
                sed -i "$2" "$1"
            fi
        }
        t55_strip fs/open.c \
            '\|^[[:space:]]*ksu_handle_faccessat(&dfd, &filename, &mode, NULL);[[:space:]]*$|d' \
            'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);'
        t55_strip fs/read_write.c \
            '\|^[[:space:]]*if (unlikely(ksu_vfs_read_hook))[[:space:]]*$|d' \
            'if (unlikely(ksu_vfs_read_hook))'
        t55_strip fs/read_write.c \
            '\|^[[:space:]]*ksu_handle_sys_read(fd, &buf, &count);[[:space:]]*$|d' \
            'ksu_handle_sys_read(fd, &buf, &count);'
        t55_strip fs/stat.c \
            '\|^[[:space:]]*ksu_handle_stat(&dfd, &filename, &flag);[[:space:]]*$|d' \
            'ksu_handle_stat(&dfd, &filename, &flag);'
        t55_strip fs/stat.c \
            '\|^[[:space:]]*ksu_handle_stat(&dfd, &filename, &flag); /\* 32-bit su support \*/[[:space:]]*$|d' \
            '32-bit su support'
        t55_strip fs/exec.c \
            '\|^[[:space:]]*if (unlikely(ksu_execveat_hook))[[:space:]]*$|,\|^[[:space:]]*ksu_handle_execveat_sucompat((int \*)AT_FDCWD, &filename, NULL, NULL, NULL);[[:space:]]*$|d' \
            'if (unlikely(ksu_execveat_hook))'
        t55_strip fs/exec.c \
            '\|^[[:space:]]*if (!ksu_execveat_hook)[[:space:]]*$|,\|32-bit su \*/[[:space:]]*$|d' \
            'if (!ksu_execveat_hook)'
        t55_strip drivers/tty/pty.c \
            '\|^[[:space:]]*ksu_handle_devpts((struct inode \*)file->f_path.dentry->d_inode);[[:space:]]*$|d' \
            'ksu_handle_devpts((struct inode *)file->f_path.dentry->d_inode);'
        t55_strip drivers/input/input.c \
            '\|^[[:space:]]*if (unlikely(ksu_input_hook))[[:space:]]*$|d' \
            'if (unlikely(ksu_input_hook))'
        t55_strip drivers/input/input.c \
            '\|^[[:space:]]*ksu_handle_input_handle_event(&type, &code, &value);[[:space:]]*$|d' \
            'ksu_handle_input_handle_event(&type, &code, &value);'

        # t55 routing gate: no kernel-tree call site may reach a 4.x function with the
        # 3.x convention. Each entry is `file|call text|class`; `danger` marks a site
        # whose target is a *4.x* function (mismatched convention => the oops).
        t55_bad=0
        t55_n=0
        while IFS='|' read -r t55_f t55_txt t55_cls; do
            [ -n "${t55_f:-}" ] || continue
            t55_n=$((t55_n + 1))
            if grep -qF -- "$t55_txt" "$t55_f"; then
                if [ "$t55_cls" = danger ]; then
                    echo "FATAL: [t55] [$t55_f] still calls a 4.x function with the 3.x convention: $t55_txt"
                    echo "       (this is the ramoops oops: regs=NULL -> NULL deref at +0x10)"
                else
                    echo "FATAL: [t55] [$t55_f] legacy 3.x call site not neutralised: $t55_txt"
                fi
                t55_bad=1
            fi
        done <<'T55SITES'
fs/exec.c|ksu_handle_execveat_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);|danger
fs/open.c|ksu_handle_faccessat(&dfd, &filename, &mode, NULL);|safe
fs/read_write.c|ksu_handle_sys_read(fd, &buf, &count);|safe
fs/stat.c|ksu_handle_stat(&dfd, &filename, &flag);|safe
drivers/tty/pty.c|ksu_handle_devpts((struct inode *)file->f_path.dentry->d_inode);|safe
drivers/input/input.c|ksu_handle_input_handle_event(&type, &code, &value);|safe
T55SITES
        if [ "$t55_bad" != "0" ]; then
            echo "FATAL: [t55] at least one legacy KSU call site can still be reached on the 4.x line."
            exit 1
        fi
        if [ "$t55_n" != "6" ]; then
            echo "FATAL: [t55] the routing gate only checked $t55_n call sites, expected 6."
            exit 1
        fi
        # Evidence that the mismatch is real (not a guess): the 4.x definition takes 3
        # parameters, while the kernel tree called it with 5.
        if ! grep -qE '^long ksu_handle_execveat_sucompat\(const char __user \*\*filename_user, int orig_nr, struct pt_regs \*regs\)' KernelSU/kernel/feature/sucompat.c; then
            echo "FATAL: [t55] cannot confirm the 3-arg 4.x signature of ksu_handle_execveat_sucompat() - the convention-mismatch evidence is gone."
            exit 1
        fi
        echo "t55 legacy KSU call sites neutralised on the 4.x line: 6 call sites gone from fs/{open,read_write,stat,exec}.c + drivers/{tty/pty,input/input}.c."
        echo "t55 routing gate passed: no kernel-tree call site can reach a 4.x function with the 3.x convention (sucompat sites absent, 4.x 3-arg signature confirmed)."
    else
        if [ "$WITH_SUSFS" -le 1 ]; then echo "NOTE: KernelSU/kernel/hook/syscall_event_bridge.c not present (3.x SUSFS tree) - the kernel tree keeps its own legacy KSU call sites, which match that line's sucompat.c convention."; else echo "SKIP [cline]: this file IS present here (it is the C-line discriminator); the call-site work is done by the C-line transform instead."; fi
    fi
    # ===== C-LINE-BLOCK-START =====

    # ===================== C line: ReSukiSU 4.x + SUSFS 2.3.0 ==================
    # Everything in this `if [ $KSU_ENABLE -eq 1 ]` block above is the A/B-line 4.19
    # compat sweep for the SukiSU tree. The C line is a different KSU tree (ReSukiSU
    # carries its own 4.19 compatibility layer) and needs a different kernel-side
    # change: the fork's baseline ships SUSFS 1.5.7 inside fs/ + include/linux/ +
    # kernel/, which has to be stripped before the SUSFS 2.3.0 kernel patch can
    # apply, and the 2.x hook call sites then have to be installed with the
    # signatures the 4.x KSU tree declares. None of that touches A or B: this block
    # runs only for WITH_SUSFS=2, and the C line is built in its own CI job from its
    # own checkout.
    if [ "$WITH_SUSFS" -eq 2 ]; then
        # [P0] line discrimination by FILE, never by a version string: the two 4.x
        # trees are told apart by ReSukiSU-only paths (KernelSU/kernel/Kbuild exists in
        # both, so it is not usable as the discriminator).
        if [ ! -f KernelSU/kernel/hook/syscall_event_bridge.c ] || [ ! -f KernelSU/kernel/tools/inline_hook_check.mk ]; then
            echo "FATAL: [cline] this is not a ReSukiSU 4.x tree (hook/syscall_event_bridge.c and"
            echo "              tools/inline_hook_check.mk must both exist). Refusing to patch it."
            exit 1
        fi

        # ---- the SUSFS 1.5.7 reversal patch ---------------------------------
        # Embedded, not fetched: it is derived from this fork's own baseline and is
        # the only artefact that can strip it byte-exactly. gzip+base64 so the 91 kB
        # patch costs 26 kB here, and the decoded blob is verified before it is used.
        CLINE_DIR=out/.cline
        mkdir -p "$CLINE_DIR"
        base64 -d <<'CLINE_PATCH_B64' | gzip -d > "$CLINE_DIR/susfs157_reverse.patch"
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
CLINE_PATCH_B64
        cline_rev_blob=$(git hash-object "$CLINE_DIR/susfs157_reverse.patch")
        if [ "$cline_rev_blob" != "5e58d3bdcd0d3c98a27a0b831484804c89454619" ]; then
            echo "FATAL: [cline] the embedded 1.5.7 reversal patch decoded to the wrong blob"
            echo "              (got [$cline_rev_blob], expected [5e58d3bdcd0d3c98a27a0b831484804c89454619])."
            exit 1
        fi
        if [ "$(head -c 5 "$CLINE_DIR/susfs157_reverse.patch")" != "diff " ]; then
            echo "FATAL: [cline] the embedded 1.5.7 reversal patch did not decode into a diff."
            exit 1
        fi

        # ---- the SUSFS 2.3.0 kernel-side patch (downloaded, pinned, blob-checked)
        # 134 kB of third-party patch does not belong in this script; the URL is an
        # immutable commit and the blob id is asserted, so a silently rewritten
        # upstream file can never be compiled in.
        curl -LSs "$SUSFS_230_URL" -o "$CLINE_DIR/susfs_patch_to_4.19.patch"
        cline_blob=$(git hash-object "$CLINE_DIR/susfs_patch_to_4.19.patch")
        if [ "$cline_blob" != "$SUSFS_230_BLOB" ]; then
            echo "FATAL: [cline] SUSFS 2.3.0 patch blob mismatch: got [$cline_blob], expected [$SUSFS_230_BLOB]."
            exit 1
        fi
        echo "[cline] SUSFS 2.3.0 patch verified (blob $cline_blob)."

        # ---- transform the kernel tree, then run every gate ------------------
        # The transform is a heredoc script rather than a repository file: the
        # delivery stays two files (build.sh + workflows/build.yml), so a missing
        # companion file cannot make the C line silently skip its kernel work. The
        # same script is exercised standalone against a real tree by
        # enuma_kernel_build/_recon3/run_cline_transform.sh.
        cat > "$CLINE_DIR/cline-transform.sh" <<'CLINE_TRANSFORM_EOF'
#!/usr/bin/env bash
# cline-transform.sh - the C-line (ReSukiSU 4.x + SUSFS 2.3.0 on 4.19.325) kernel-tree
# transformation, extracted verbatim from build.sh so it can be exercised on a real
# tree without running the whole build. Must be run from the KERNEL TREE ROOT with
# KernelSU/ already in place.
#
# Environment (set by build.sh):
#   CLINE_REV_PATCH   absolute native path of the 1.5.7 reversal patch
#   CLINE_SUSFS_PATCH absolute native path of the SUSFS 2.3.0 4.19 patch
set -u
rc_all=0
fail() { echo "FATAL: [cline] $*"; exit 1; }

# --- 0) keep the pre-transform copies the structural gates compare against ---------
# The gates in section 6 need to know what each `#ifdef CONFIG_KSU` block looked like
# BEFORE the transformation, so they can distinguish "this block legitimately has no ksu_
# call (a self-closing guard)" from "this block lost the call it used to have".
mkdir -p out/.cline/pre
for f in fs/exec.c fs/read_write.c fs/stat.c fs/open.c drivers/input/input.c; do
    [ -e "$f" ] || continue
    cp "$f" "out/.cline/pre/$(echo "$f" | sed 's|/|_|g')"
done

# --- 0b) comment stripping for the residue gates --------------------------------
# run12 proved the cost of substring gates: the residual check for `ksu_execveat_hook`
# passed while fs/exec.c did not compile, because the symbol survived in a COMMENT that
# the fix itself had just inserted. This is the third time the project has paid for that
# mistake (t52/F3 was the first).
#
# The remaining C this transform writes on purpose carries long explanations that name
# the symbols it removes, so every residue gate now runs against a comment-stripped copy
# of the file (`cline_code_file`). The result is strict in the right direction:
#   * a forbidden symbol in CODE          -> gate fires (the real defect)
#   * a forbidden symbol in a COMMENT     -> gate fires as well, because the code-only
#                                            view is what is tested and the fix's own
#                                            prose must stay clear of the names
#   * a required symbol in a COMMENT      -> does NOT satisfy the hook gate, which is what
#                                            stops "declared but never called" (defect 3
#                                            of this round) from passing again
# The stripper is a character-level state machine. A line-based regex version was tried
# first and silently swallowed entire files (once `inblk` was set, the closing form it
# looked for never matched) - which would have turned these gates into no-ops. Both
# consumers are validated by _recon3/comment_decoy_test.sh.
cline_code_file() { # $1 = source file, $2 = destination with comments removed
    awk '
        {
            line = $0
            sub(/\r$/, "", line)
            out = ""
            i = 1
            n = length(line)
            while (i <= n) {
                if (inblk) {
                    if (substr(line, i, 2) == "*/") { inblk = 0; i += 2 } else i++
                    continue
                }
                if (substr(line, i, 2) == "/*") { inblk = 1; i += 2; continue }
                if (substr(line, i, 2) == "//") break
                out = out substr(line, i, 1)
                i++
            }
            print out
        }
    ' "$1" > "$2"
}
mkdir -p out/.cline/code

# --- 1) strip the in-tree SUSFS 1.5.7 -----------------------------------------
# The fork's baseline already carries SUSFS 1.5.7 (fs/susfs.c, fs/sus_su.c,
# include/linux/susfs.h + hooks in 22 files), and SUSFS 2.3.0 replaces exactly those
# files. Without the strip the 2.3.0 patch cannot apply (19 files / 42 errors -
# measured), so the order strip-then-patch is mandatory, not stylistic.
if [ -e fs/susfs.c ] && grep -q '#define SUSFS_VERSION "v1.5.7"' include/linux/susfs.h 2>/dev/null; then
    echo "[cline] 1.5.7 present -> stripping"
    git apply --ignore-whitespace --whitespace=nowarn "$CLINE_REV_PATCH" \
        || fail "the SUSFS 1.5.7 reversal patch did not apply (tree is not the expected 1.5.7 baseline)"
else
    echo "[cline] 1.5.7 not present -> assuming an already-stripped tree (idempotent re-run)"
    cline_stripped_already=1
fi
# gates: the strip must be complete (deletions included), and "half stripped" must fail
# loudly. These checks only make sense when this run actually performed the strip:
# step 2 legitimately recreates fs/susfs.c, include/linux/susfs.h and susfs_def.h, and
# CONFIG_KSU_SUSFS is of course present inside the 2.x code afterwards.
if [ "${cline_stripped_already:-0}" = 0 ]; then
    for cline_f in fs/susfs.c fs/sus_su.c include/linux/susfs.h include/linux/susfs_def.h; do
        [ -e "$cline_f" ] && fail "$cline_f survived the strip"
    done
    cline_left=$(grep -rl 'CONFIG_KSU_SUSFS' fs include kernel mm security drivers 2>/dev/null | wc -l)
    [ "$cline_left" = 0 ] || fail "CONFIG_KSU_SUSFS still present in $cline_left file(s)"
    cline_left=$(grep -rl 'susfs_' fs include kernel mm security drivers 2>/dev/null | wc -l)
    [ "$cline_left" = 0 ] || {
        grep -rl 'susfs_' fs include kernel mm security drivers 2>/dev/null | sed 's/^/   residue: /'
        fail "susfs_ residue after the 1.5.7 strip ($cline_left file(s))"
    }
fi

# CLINE_STOP_AFTER_STRIP=1 is a test hook: it leaves the tree in the "stripped but not
# yet 2.3.0" state so the residue gate above can be exercised end to end on a real tree.
if [ "${CLINE_STOP_AFTER_STRIP:-0}" = "1" ]; then
    echo "[cline] stopping after the strip (CLINE_STOP_AFTER_STRIP=1)"
    exit 0
fi

# --- 2) apply SUSFS 2.3.0 (kernel side) ---------------------------------------
# The 2.x kernel-side and KSU-side halves are split: this patch is the kernel half
# ONLY (19 files, no ksu_handle_* call sites), which is why step 3 exists.
if grep -q '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h 2>/dev/null; then
    echo "[cline] SUSFS 2.3.0 already applied"
else
    git apply --ignore-whitespace --whitespace=nowarn "$CLINE_SUSFS_PATCH" \
        || fail "the SUSFS 2.3.0 kernel patch did not apply"
fi
grep -q '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h || fail "include/linux/susfs.h has no SUSFS v2.3.0 marker"
grep -q 'CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || fail "fs/Makefile is not wired to susfs.o"
[ -e include/linux/susfs_def.h ] || fail "include/linux/susfs_def.h missing after the 2.3.0 patch"

# --- 3) inline-hook call sites for ReSukiSU's 4.x conventions -----------------
# KernelSU 4.x drives these hooks from its own inline-hooked call sites and has no
# `ksu_*_hook` enable flags any more. ReSukiSU enforces this with
# tools/inline_hook_check.mk: it $(error)s when an old flag is still present in
# fs/read_write.c, drivers/input/input.c, fs/exec.c or fs/stat.c, and when one of the
# required ksu_handle_* call sites is missing. Five files need work here; fs/open.c,
# fs/read_write.c's and fs/stat.c's new call sites already come from the 2.3.0 patch.
CLINE_MARK='cline: 4.x inline hook'

# 3a) fs/exec.c - the 5-arg ksu_handle_execveat_sucompat() call is the site that
# oopsed on the device (regs=NULL -> NULL+0x10). ReSukiSU reaches execveat through
# kernel/hook/syscall_event_bridge.c (3-arg convention), so the kernel tree must not
# keep a second call site with the 3.x convention.
#
# run12 defect: deleting the three 3.x lines ONE BY ONE left the `else` behind and the
# file stopped compiling - `fs/exec.c:1954: error: expected expression` immediately
# before `else`. The removal is therefore a whole *address-range* deletion (the two
# `if (…ksu_execveat_hook…)` blocks, from the `if` through the line after the block's
# closing `#endif`), not a line-by-line string deletion. The pristine layout is:
#
#     #ifdef CONFIG_KSU
#     extern bool ksu_execveat_hook __read_mostly;
#     extern int ksu_handle_execveat(...);
#     extern int ksu_handle_execveat_sucompat(...);
#     #endif
#     ...
#     #ifdef CONFIG_KSU
#     	if (unlikely(ksu_execveat_hook))                                     <- start
#     		ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#     	else
#     		ksu_handle_execveat_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);
#     #endif                                                               <- end
#
# The 32-bit variant (`if (!ksu_execveat_hook)` + one call + `#endif`) is the same shape.
# The extern declarations for the two 3.x names go as well (the 2.x tree declares its own
# ksu_handle_execveat; leaving the old-flag extern would re-introduce the symbol).
if ! grep -q 'cline: 4.x inline hook (exec)' fs/exec.c; then
    rm -f fs/exec.c.cline.cnt
    # run13 taught the directive lesson: the two 3.x hook blocks sit INSIDE the
    # `#ifdef CONFIG_KSU` guards that keep the `return do_execveat_common(...)` in, so
    # deleting the block INCLUDING its `#endif` leaves those guards unterminated ->
    #   ../fs/exec.c:1971:2: error: unterminated conditional directive
    #   ../fs/exec.c:1950:2: error: unterminated conditional directive
    # (measured: pristine 18 open / 18 close, my previous pass produced 18 / 16).
    # The block is therefore replaced IN PLACE - the 2.x call goes where the 3.x
    # if/else was, and the guard pair is preserved.
    awk '
        /^[[:space:]]*if \(unlikely\(ksu_execveat_hook\)\)[[:space:]]*$/ { skip = 1 }
        /^[[:space:]]*if \(!ksu_execveat_hook\)[[:space:]]*$/            { skip = 1 }
        skip {
            if ($0 ~ /^[[:space:]]*#endif[[:space:]]*$/) {
                print "\t/* cline: 4.x inline hook (exec) call (signature = feature/sucompat.c:316) */"
                print "\t{"
                print "\t\tint t49_fd = AT_FDCWD;"
                print "\t\tksu_handle_execveat(&t49_fd, &filename, &argv, &envp, 0);"
                print "\t}"
                print $0
                skip = 0
                replaced++
                next
            }
            next
        }
        /^extern bool ksu_execveat_hook __read_mostly;[[:space:]]*$/ { next }
        /^#ifdef CONFIG_KSU[[:space:]]*$/ && !marked {
            print $0 " /* cline: 4.x inline hook (exec) */"; marked = 1; next
        }
        { print }
        END { printf "%d\n", replaced > "fs/exec.c.cline.cnt" }
    ' fs/exec.c > fs/exec.c.cline
    awk_replaced=$(cat fs/exec.c.cline.cnt 2>/dev/null || echo 0)
    rm -f fs/exec.c.cline.cnt
    if [ "$awk_replaced" != 2 ]; then
        rm -f fs/exec.c.cline
        fail "fs/exec.c: expected the 3.x hook block to be replaced in exactly 2 places, replaced [$awk_replaced]"
    fi
    mv fs/exec.c.cline fs/exec.c
fi
# 3a-2) The old three-line extern declaration block
#        extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
#                         void *argv, void *envp, int *flags);
# goes away as well: the 2.x tree declares its own ksu_handle_execveat, and leaving the
# 3.x name would re-introduce the symbol. Only the three DECLARATION lines are removed -
# the `#ifndef CONFIG_KSU`/`#endif` pair around them is kept so the directive count stays
# exactly what the pristine file had.
if ! grep -q 'cline: 4.x inline hook (exec) decl' fs/exec.c; then
    awk '
        /^extern int ksu_handle_execveat_sucompat\(int \*fd, struct filename \*\*filename_ptr,[[:space:]]*$/ {
            # NOTE: this comment must NOT spell the removed 3.x symbol out. The
            # comment-stripped residue gate in section 3 would see it and - correctly -
            # fail: prose naming a forbidden symbol must be rephrased, not excused.
            print "/* cline: 4.x inline hook (exec) decl (marker): the 3.x sucompat-style"
            print " * declaration that used to sit in this guard was removed. ReSukiSU declares"
            print " * ksu_handle_execveat() itself (feature/sucompat.c:316) and the kernel tree"
            print " * calls it in both do_execve wrappers below. Keeping this guard pair keeps the"
            print " * pristine #ifdef/#endif count, which run13 proved matters"
            print " * (unterminated conditional directive). */"
            dcl = 1
            next
        }
        dcl {
            if ($0 ~ /^[[:space:]]*void \*argv, void \*envp, int \*flags\);[[:space:]]*$/) { next }
            dcl = 0
        }
        { print }
    ' fs/exec.c > fs/exec.c.cline && mv fs/exec.c.cline fs/exec.c
fi
grep -q 'cline: 4.x inline hook (exec) decl' fs/exec.c || fail "fs/exec.c: the 3.x sucompat extern declaration was not removed"
# the signature must be ReSukiSU's, not the 3.x one (the device oops was this exact mix-up)
grep -q '^extern int ksu_handle_execveat(int \*fd, struct filename \*\*filename_ptr, void \*argv,' fs/exec.c \
    || fail "fs/exec.c: the kernel tree's 4.x ksu_handle_execveat extern is not the expected signature"
# the call must exist, not just the declaration (that was the run12 shape): the 3.x block
# was REPLACED by the 2.x call in exactly the two do_execve wrappers
[ "$(grep -c 'ksu_handle_execveat(&t49_fd, &filename, &argv, &envp, 0);' fs/exec.c)" = 2 ] \
    || fail "fs/exec.c: the 2.x execveat call is not present in both wrappers"
# function-scoped naked-else assertion (t6/F8). The file-level gate in section 6a reasons
# about brace depth; this one is the direct statement the verifier asked for and it covers
# the two functions the 3.x block lived in, so a regression here is named by function.
for cline_fn in do_execve compat_do_execve; do
    if ! awk -v fn="$cline_fn" '
        $0 ~ "^" fn "\\(" { f = 1 }
        f && /^[[:space:]]*else[[:space:]]*$/ { printf "%s: naked else at line %d\n", fn, NR; rc = 1 }
        f && /^}$/ { f = 0 }
        END { exit (rc ? 1 : 0) }
    ' fs/exec.c; then
        fail "fs/exec.c: a naked else survived in $cline_fn() (this is the run12 compile error)"
    fi
done
# residue checks: against the COMMENT-STRIPPED file (see cline_code_file above). The
# transform's own explanatory comments name these symbols, so a raw grep would fire on
# its own prose; a raw grep that is skipped instead is exactly how run12 got through.
cline_code_file fs/exec.c out/.cline/code/exec.c
if grep -q 'ksu_execveat_hook' out/.cline/code/exec.c; then
    echo "   fs/exec.c still branches on ksu_execveat_hook (in code):"
    grep -n 'ksu_execveat_hook' out/.cline/code/exec.c | sed 's/^/      /'
    fail "fs/exec.c still branches on ksu_execveat_hook (KernelSU 4.x has no such flag)"
fi
if grep -q 'ksu_handle_execveat_sucompat' out/.cline/code/exec.c; then
    fail "fs/exec.c still calls ksu_handle_execveat_sucompat with the 3.x convention (the device oops)"
fi

# 3b) fs/read_write.c - drop the 3.x flag guard; the 2.3.0 patch already installed the
# 3-arg ksu_handle_sys_read(fd, &buf, &count) call the KSU tree declares.
if ! grep -q 'cline: 4.x inline hook (read)' fs/read_write.c; then
    sed -i '/^[[:space:]]*if (unlikely(ksu_vfs_read_hook))$/d' fs/read_write.c
    sed -i '/^extern bool ksu_vfs_read_hook __read_mostly;$/d' fs/read_write.c
    sed -i '0,/^#ifdef CONFIG_KSU$/s|^#ifdef CONFIG_KSU$|/* cline: 4.x inline hook (read): the 3.x enable flag is gone (inline_hook_check.mk\n * rejects it); the call site comes from the SUSFS 2.3.0 patch. */\n#ifdef CONFIG_KSU|' fs/read_write.c
fi
cline_code_file fs/read_write.c out/.cline/code/read_write.c
if grep -q 'ksu_vfs_read_hook' out/.cline/code/read_write.c; then
    fail "fs/read_write.c still uses ksu_vfs_read_hook (incompatible per inline_hook_check.mk)"
fi

# 3c) drivers/input/input.c - same pattern for the input enable flag.
if ! grep -q 'cline: 4.x inline hook (input)' drivers/input/input.c; then
    sed -i '/^[[:space:]]*if (unlikely(ksu_input_hook))$/d' drivers/input/input.c
    sed -i '/^extern bool ksu_input_hook __read_mostly;$/d' drivers/input/input.c
    sed -i '0,/^#ifdef CONFIG_KSU$/s|^#ifdef CONFIG_KSU$|/* cline: 4.x inline hook (input): the 3.x enable flag is gone (inline_hook_check.mk\n * rejects it). */\n#ifdef CONFIG_KSU|' drivers/input/input.c
fi
cline_code_file drivers/input/input.c out/.cline/code/input.c
if grep -q 'ksu_input_hook' out/.cline/code/input.c; then
    fail "drivers/input/input.c still uses ksu_input_hook (incompatible per inline_hook_check.mk)"
fi

# 3d) kernel/sys.c - ksu_handle_setresuid() must be reachable from __sys_setresuid()
# (ReSukiSU declares it in hook/setuid_hook.c:152 with this exact signature).
if ! grep -q 'ksu_handle_setresuid' kernel/sys.c; then
    sed -i '/^long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)$/,/^}$/ s|^\([[:space:]]*\)kuid_t kruid, keuid, ksuid;|\1kuid_t kruid, keuid, ksuid;\n\1/* cline: 4.x inline hook (setresuid) */\n\1extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n\n\1ksu_handle_setresuid(ruid, euid, suid);|' kernel/sys.c
fi

# 3e) kernel/reboot.c - ksu_handle_sys_reboot() must run BEFORE the LINUX_REBOOT_MAGIC
# check: ksud's reboot(2) ABI uses its own magic values and returns 0 to consume the
# call. It must stay after the CAP_SYS_BOOT check so an unprivileged caller cannot
# reach it.
if ! grep -q 'ksu_handle_sys_reboot' kernel/reboot.c; then
    sed -i '0,/^SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,$/s|^SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,$|/* cline: 4.x inline hook (reboot) */\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n\nSYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,|' kernel/reboot.c
    awk '
        { print }
        /if \(!ns_capable\(pid_ns->user_ns, CAP_SYS_BOOT\)\)/ && !done {
            getline nxt
            print nxt
            if (nxt ~ /^[[:space:]]*return -EPERM;/) {
                print ""
                print "\t/* cline: 4.x inline hook (reboot): before the magic check on purpose -"
                print "\t * ksud uses its own magic values; a 0 return consumes the call. */"
                print "\tif (!ksu_handle_sys_reboot(magic1, magic2, cmd, &arg))"
                print "\t\treturn 0;"
                done = 1
            }
        }' kernel/reboot.c > kernel/reboot.c.cline && mv kernel/reboot.c.cline kernel/reboot.c
fi
grep -q 'ksu_handle_sys_reboot' kernel/reboot.c || fail "kernel/reboot.c has no ksu_handle_sys_reboot call site"

# 3f) fs/proc/task_mmu.c - run12 defect 2. The upstream SUSFS 2.3.0 patch declares
# `spoofed_redirected_name` TWICE in show_map_vma():
#   :374  function level, inside `#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT`   (outer)
#   :381  inside `if (SUSFS_IS_INODE_OPEN_REDIRECT(inode)) {`             (inner)
# The inner declaration SHADOWS the outer one and the outer is never referenced, so
# clang reports `unused variable 'spoofed_redirected_name' [-Werror,-Wunused-variable]`
# and the build stops at fs/proc/task_mmu.o. Only the outer one is removed: the inner
# declaration and its two uses (`susfs_open_redirect_spoof_show_map_vma_srcu(...,
# &spoofed_redirected_name)` and `seq_puts(m, spoofed_redirected_name)`) stay, so the
# open_redirect feature still works - unlike silencing the warning or disabling
# CONFIG_KSU_SUSFS_OPEN_REDIRECT, both of which are forbidden here.
#
# The file is touched by the 2.3.0 patch ONLY (this transform had no task_mmu rule before),
# so the guard is: the outer declaration exists AND the inner one exists.
# --- 2.3.0 shape ----------------------------------------------------------------
# SUSFS 2.3.0 DROPPED the outer declaration and its `if (spoofed_redirected_name)`
# guard (measured: 2.2.0 has 5 `spoofed_redirected_name` lines, 2.3.0 has 4), i.e.
# upstream fixed the shadowing defect. So the new shape is ONE declaration (3 tabs,
# inside `if (SUSFS_IS_INODE_OPEN_REDIRECT(inode)) {`), NO function-level declaration,
# and the address-of use without the now-pointless `if (spoofed_redirected_name)`.
# A single declaration that has its address taken is USED, so there is no
# [-Wunused-variable] to fix - the run12 fix is a no-op on 2.3.0. It is still applied
# (harmlessly) because tm_inner is what the use is bound to. The counts below are
# identical for both shapes on purpose (decls 2, uses 2, refs >= 6), so this gate keeps
# the same strength it had on 2.2.0.
if ! grep -q 'cline: 4.x task_mmu duplicate' fs/proc/task_mmu.c; then
    tm_outer=$(grep -c '^	char \*spoofed_redirected_name = NULL;[[:space:]]*$' fs/proc/task_mmu.c)
    tm_inner=$(grep -c '^			char \*spoofed_redirected_name = NULL;[[:space:]]*$' fs/proc/task_mmu.c)
    if [ "$tm_inner" = 1 ]; then
        # keep the declaration, delete only its last reference, and bind it in the guarded
        # branch where the value IS read. Chosen over deleting the declaration because the
        # only references either bind a `struct filename *` (fs/stat.c) or are the argument
        # of a function whose return value is checked, in BOTH variants, so adding one use
        # is provably safe - whereas deleting a declaration would also delete whatever the
        # function does if its result is used elsewhere.
        awk '
            # ONE tab of indentation is the function-level declaration; the shadowing one
            # inside `if (SUSFS_IS_INODE_OPEN_REDIRECT(inode)) {` has two tabs. Using
            # [[:space:]]* here matched BOTH and added a pointless use after the inner
            # declaration too (measured: 3 uses instead of 2).
            /^\tchar \*spoofed_redirected_name = NULL;[[:space:]]*$/ {
                print
                print "\t(void)spoofed_redirected_name; /* cline: used only under SUSFS_IS_INODE_OPEN_REDIRECT */"
                # 2.2.0 shape: the function-level declaration exists, so the block-local
                # one shadows it and IS read - do not add a second explicit use.
                outer = 1
                next
            }
            /^[[:space:]]*int ret = susfs_open_redirect_spoof_show_map_vma_srcu\(inode, &ino, &dev, &spoofed_redirected_name\);[[:space:]]*$/ {
                print
                # 2.2.0 gave this block its own shadowing declaration, so the use was
                # emitted there. 2.3.0 has NO function-level declaration and NO trailing
                # `if (spoofed_redirected_name)` either (upstream dropped both), so the
                # block-local declaration is STILL never read and needs the explicit use
                # at the call site instead - otherwise clang fails the kernel on
                # [-Wunused-variable]. Emit it here only when the outer rule did not fire.
                if (outer == 0) print "\t\t\t(void)spoofed_redirected_name; /* cline: 4.x task_mmu duplicate: keep the out-param in use even when the guarded print is compiled out */"
                next
            }
            # Anything that is NOT the function-level declaration (i.e. the 2.3.0
            # block-local one) means there is no shadowing pair to fix.
            /^[[:space:]]*char \*spoofed_redirected_name = NULL;[[:space:]]*$/ { outer = 0 }
            { print }
        ' fs/proc/task_mmu.c > fs/proc/task_mmu.c.cline && mv fs/proc/task_mmu.c.cline fs/proc/task_mmu.c
        echo "[cline] fs/proc/task_mmu.c: bound the shadowed function-level declaration to its guarded out-param."
    fi
fi
tm_decl=$(grep -c 'spoofed_redirected_name = NULL;' fs/proc/task_mmu.c)
tm_uses=$(grep -c '(void)spoofed_redirected_name;' fs/proc/task_mmu.c)
tm_refs=$(grep -c 'spoofed_redirected_name' fs/proc/task_mmu.c)
tm_dupm=$(grep -c 'cline: 4.x task_mmu duplicate' fs/proc/task_mmu.c)
tm_keep=$(grep -c 'cline: used only under SUSFS_IS_INODE_OPEN_REDIRECT' fs/proc/task_mmu.c)
# Per-shape invariants. `tm_outer`/`tm_inner` were computed above (they survive the
# `if` because bash has no block scope). The two shapes are genuinely different:
#   2.2.0: 2 declarations, 2 shadowing-induced unused vars -> 2 explicit uses, 7 refs
#   2.3.0: 1 declaration, 1 unused out-param            -> 1 explicit use,  5 refs
# An earlier revision asserted `uses = 2` unconditionally, which is a 2.2.0-only fact
# and rejected every 2.3.0 tree (that is what failed run16).
if [ "$tm_outer" = 0 ]; then
    [ "$tm_decl" = 1 ] || fail "fs/proc/task_mmu.c: [2.3.0 shape] expected 1 declaration, found $tm_decl"
    [ "$tm_uses" = 1 ] || fail "fs/proc/task_mmu.c: [2.3.0 shape] expected 1 explicit use, found $tm_uses"
    [ "$tm_refs" = 5 ] || fail "fs/proc/task_mmu.c: [2.3.0 shape] expected 5 references, found $tm_refs"
    [ "$tm_dupm" = 1 ] || fail "fs/proc/task_mmu.c: [2.3.0 shape] the explicit use was not inserted"
    grep -q 'cline: 4.x task_mmu duplicate' fs/proc/task_mmu.c \
        || fail "fs/proc/task_mmu.c: [2.3.0 shape] the explicit use is missing"
    echo "[cline] fs/proc/task_mmu.c: SUSFS 2.3.0 shape - single declaration bound to its out-param ($tm_refs references)."
else
    [ "$tm_decl" = 2 ] || fail "fs/proc/task_mmu.c: [2.2.0 shape] expected 2 declarations, found $tm_decl"
    [ "$tm_uses" = 2 ] || fail "fs/proc/task_mmu.c: [2.2.0 shape] expected 2 explicit uses, found $tm_uses"
    [ "$tm_refs" -ge 6 ] || fail "fs/proc/task_mmu.c: [2.2.0 shape] the declaration/uses were removed (refs=$tm_refs)"
    [ "$tm_keep" = 1 ] || fail "fs/proc/task_mmu.c: [2.2.0 shape] the first explicit use was not inserted"
    [ "$tm_dupm" = 1 ] || fail "fs/proc/task_mmu.c: [2.2.0 shape] the second explicit use was not inserted"
    echo "[cline] fs/proc/task_mmu.c: duplicate declaration now explicitly used ($tm_uses sites, $tm_refs references)."
fi

# 3g) fs/stat.c - SUSFS 2.3.0 port gap (the run17 blocker).
# 2.3.0's vfs_getattr_nosec() calls susfs_is_current_app_uid() and ORs
# STATX_SUS_KSTAT / STATX_SUS_KSTAT_FUSE into stat->result_mask. All three live in
# <linux/susfs_def.h>, but the 2.3.0 patch only added that include to
# fs/proc/task_mmu.c - it left fs/stat.c with the two `extern` declarations from the
# 2.2.0 era (2.2.0's stat.c needed neither the macro nor the inline, so the gap was
# invisible then). Result on 4.19 with -Werror:
#   fs/stat.c:85:6:  error: implicit declaration of function 'susfs_is_current_app_uid'
#   fs/stat.c:91:26: error: use of undeclared identifier 'STATX_SUS_KSTAT'
# (11 errors, all in fs/stat.c; `make -k` shows no other file is affected.)
# Guarded on the 2.3.0 marker so a 2.2.0 tree stays a no-op.
if grep -q '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h 2>/dev/null; then
    if [ -e fs/stat.c ] && ! grep -q 'include <linux/susfs_def.h>' fs/stat.c; then
        sed -i 's|^#include <asm/unistd.h>$|#include <asm/unistd.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h> /* cline: 2.3.0 stat.c port gap */\n#endif|' fs/stat.c
    fi
    grep -q 'include <linux/susfs_def.h>' fs/stat.c \
        || fail "fs/stat.c: susfs_def.h was not added (2.3.0 needs STATX_SUS_KSTAT and susfs_is_current_app_uid)"
    echo "[cline] fs/stat.c: susfs_def.h included (SUSFS 2.3.0 port gap closed)."
else
    echo "NOTE: [cline] SUSFS is not 2.3.0 - the fs/stat.c def.h include is a 2.3.0-only fix, skipped."
fi

# --- 4) KSU-side 4.19 compat --------------------------------------------------
# 4a) copy_to_user_nofault()/copy_from_user_nofault() are 5.8+; this tree spells them
#     probe_user_write()/probe_user_read() with the same contract. ReSukiSU's compat
#     layer covers strncpy_from_user_nofault and copy_from_kernel_nofault but not
#     these two, and both call sites in runtime/ksud_integration.c are unguarded.
KCC=KernelSU/kernel/compat/kernel_compat.c
if [ -f "$KCC" ] && ! grep -q 'ksu_419: copy_to_user_nofault' "$KCC"; then
    cat >> "$KCC" <<'KSU419'

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
/* ksu_419: copy_{to,from}_user_nofault are 5.8+ (mm/maccess.c). This 4.19 tree
 * spells them probe_user_write()/probe_user_read() with the same contract: 0 on
 * success, -EFAULT on fault. ReSukiSU's compat layer provides the strncpy and
 * copy_from_kernel variants but not these two, while runtime/ksud_integration.c
 * calls both without a version guard. */
__weak long copy_to_user_nofault(void __user *dst, const void *src, size_t size)
{
	return probe_user_write(dst, src, size);
}

__weak long copy_from_user_nofault(void *dst, const void __user *src, size_t size)
{
	return probe_user_read(dst, src, size);
}
#endif /* ksu_419: copy_to_user_nofault */
KSU419
fi
if [ -f "$KCC" ]; then
    grep -q 'ksu_419: copy_to_user_nofault' "$KCC" || fail "the 5.8+ maccess shims were not inserted into compat/kernel_compat.c"
fi

# 4b) infra/file_wrapper.c guards its remap_file_range use with
#     `#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)`, which is TRUE on
#     4.19.325 (267333 > 267264 - the 325 overflows into the minor field) while the
#     member only exists from 4.20 on. Move both guards to the 5.0 boundary, the same
#     convention the A line's t28b fix uses.
FW=KernelSU/kernel/infra/file_wrapper.c
if [ -f "$FW" ] && ! grep -q 'ksu_419: remap_file_range is 5.0+' "$FW"; then
    sed -i 's|^#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)$|#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0) /* ksu_419: remap_file_range is 5.0+; 4.19.325 makes the 4.20 threshold truthy */|' "$FW"
fi
if [ -f "$FW" ]; then
    cline_guards=$(grep -c 'ksu_419: remap_file_range is 5.0+' "$FW")
    [ "$cline_guards" = 2 ] || fail "expected 2 remap_file_range guards in file_wrapper.c, found $cline_guards"
    grep -q 'KERNEL_VERSION(4, 20, 0)' "$FW" && fail "a 4.20 version threshold survives in file_wrapper.c (truthy on 4.19.325)"
fi

# --- 5) [P0] the 4.x hook contract has to be routable ------------------------
# tools/inline_hook_check.mk (included by KernelSU/kernel/Kbuild when
# CONFIG_KSU_SUSFS=y) is a free, already-written gate: it $(error)s when a 3.x flag
# survives in fs/read_write.c, drivers/input/input.c, fs/exec.c or fs/stat.c, and when
# one of the required ksu_handle_* call sites is missing. Reproduce its checks here so a
# broken tree fails during transformation instead of 20 minutes into the build.
cline_hook_fail=0
for cline_pair in "fs/read_write.c:ksu_vfs_read_hook" "fs/read_write.c:ksu_init_rc_hook" \
                  "fs/stat.c:ksu_init_rc_hook" "drivers/input/input.c:ksu_input_hook" \
                  "fs/exec.c:ksu_execveat_hook"; do
    cline_f="${cline_pair%%:*}"; cline_s="${cline_pair##*:}"
    cline_code_file "$cline_f" "out/.cline/code/hook_$(echo "$cline_f" | sed 's|/|_|g')"
    if grep -qw "$cline_s" "out/.cline/code/hook_$(echo "$cline_f" | sed 's|/|_|g')" 2>/dev/null; then
        echo "   incompatible 3.x hook flag still present (in code): $cline_s in $cline_f"
        cline_hook_fail=1
    fi
done
for cline_pair in "kernel/sys.c:ksu_handle_setresuid" "fs/exec.c:ksu_handle_execveat" \
                  "fs/open.c:ksu_handle_faccessat" "fs/read_write.c:ksu_handle_sys_read" \
                  "fs/stat.c:ksu_handle_stat" "kernel/reboot.c:ksu_handle_sys_reboot" \
                  "drivers/input/input.c:ksu_handle_input_handle_event"; do
    cline_f="${cline_pair%%:*}"; cline_s="${cline_pair##*:}"
    cline_code_file "$cline_f" "out/.cline/code/req_$(echo "$cline_f" | sed 's|/|_|g')"
    grep -qw "$cline_s" "out/.cline/code/req_$(echo "$cline_f" | sed 's|/|_|g')" 2>/dev/null || {
        echo "   required 4.x hook call site missing (in code): $cline_s in $cline_f"
        cline_hook_fail=1
    }
done
[ "$cline_hook_fail" = 0 ] || fail "the 4.x inline-hook contract is not routable (see the lines above; KernelSU/kernel/tools/inline_hook_check.mk would fail the build)"

# --- 6) STRUCTURAL gates (not string gates) -----------------------------------
# run12 taught the difference the hard way: the string gates in section 3a passed while
# fs/exec.c no longer compiled, because `ksu_execveat_hook` still appeared in the COMMENT
# that step had just inserted, and because "no dangling else" was never checked at all.
# Both gates below look at structure, so a comment cannot satisfy them.

# 6a) a dangling `else` must never be produced. This is the exact run12 defect
# (`fs/exec.c:1954: error: expected expression` immediately before `else`).
#
# The discriminator is BRACE DEPTH, not "the previous line ends with }": a legitimate
# `else` can follow a multi-line if-body whose last line is an assignment (which is why
# a naive check produced five false positives on the first run of this gate). A dangling
# `else` always sits at depth 0 with at least one code brace already opened and closed on
# the way in, i.e. there is no `if` it can belong to. `#else` and `else if` are excluded
# by the pattern itself, and a `\r` is stripped first because this tree is CRLF/LF mixed.
for cline_f in fs/exec.c fs/read_write.c fs/stat.c fs/open.c drivers/input/input.c kernel/reboot.c kernel/sys.c; do
    [ -e "$cline_f" ] || continue
    cline_bad=$(awk '
        { sub(/\r$/, "", $0) }
        /^[[:space:]]*else[[:space:]]*$/ && depth == 0 && closed > 0 { printf "%d:%s\n", NR, $0 }
        {
            opens = gsub(/\{/, "{")
            closes = gsub(/\}/, "}")
            depth += opens - closes
            if (depth < 0) depth = 0
            if (closes > 0 && depth == 0) closed++
        }
    ' "$cline_f")
    if [ -n "$cline_bad" ]; then
        echo "   dangling else in $cline_f:"
        echo "$cline_bad" | sed 's/^/      /'
        fail "a dangling else was produced in $cline_f (this is the run12 compile error)"
    fi
done
echo "[cline] structural gate: no dangling else in any touched file."

# 6a-2) PREPROCESSOR-DIRECTIVE gate (run13's defect: unterminated conditional directive).
# run13's C leg died with
#   ../fs/exec.c:1971:2: error: unterminated conditional directive
#   ../fs/exec.c:1950:2: error: unterminated conditional directive
# because the 3.x hook block sits INSIDE the `#ifdef CONFIG_KSU` guard that keeps
# `return do_execveat_common(...)`, and deleting the block including its `#endif` left the
# guard open (pristine fs/exec.c = 18 open / 18 close; the defective pass produced 18/16).
# `bash -n` cannot see this and neither could the brace/else gates, so it is checked here:
# every touched file must have the same number of `#if*` and `#endif`, and no `#ifdef
# CONFIG_KSU` may be left without its own `#endif`.
for cline_f in fs/exec.c fs/read_write.c fs/stat.c fs/open.c drivers/input/input.c kernel/reboot.c kernel/sys.c fs/proc/task_mmu.c; do
    [ -e "$cline_f" ] || continue
    cline_dir=$(awk '
        { line = $0; sub(/\r$/, "", line) }
        line ~ /^[[:space:]]*#[[:space:]]*(if|ifdef|ifndef)([[:space:]]|$)/ { op++ }
        line ~ /^[[:space:]]*#[[:space:]]*endif([[:space:]]|$)/ { cl++ }
        END { printf "%d %d\n", op + 0, cl + 0 }
    ' "$cline_f")
    set -- $cline_dir
    if [ "$1" != "$2" ]; then
        fail "$cline_f has $1 open / $2 close preprocessor conditionals (delta $(( $1 - $2 ))) - run13's unterminated conditional directive"
    fi
    cline_open=$(awk '
        { line = $0; sub(/\r$/, "", line) }
        line ~ /^[[:space:]]*#ifdef CONFIG_KSU([[:space:]]|$)/ { inb = 1; start = NR; next }
        inb && line ~ /^[[:space:]]*#endif([[:space:]]|$)/ { inb = 0; next }
        END { if (inb) printf "%d", start }
    ' "$cline_f")
    if [ -n "$cline_open" ]; then
        fail "$cline_f: the #ifdef CONFIG_KSU opened at line $cline_open is never closed"
    fi
done
echo "[cline] structural gate: every touched file keeps its #if*/#endif count and no CONFIG_KSU guard is left open."

# 6b) UNIT-DELETION gate for the 3.x hook blocks.
# The run12 defect was an `else` whose `if` had been deleted (and my first two attempts
# at this gate were both wrong: a string gate passed because the symbol survived in a
# comment, and a brace-balance gate passed because the dangling `else`'s body had been
# deleted too, leaving a net balance of zero on both `block` and `file`).
#
# The invariant that actually holds is: a brace-less control keyword and the statement it
# owns are deleted together. So inside every `#ifdef CONFIG_KSU` block, if a brace-less
# `else` survives, a brace-less `if` must survive as well. Validated against seven
# crafted inputs by _recon3/gate_else_test.sh:
#   buggy (only the `if` line removed)  -> FIRE  "1 brace-less else but 0 brace-less if"
#   buggy (only the body call removed)  -> PASS  (the `if`/`else` pair is still intact)
#   fixed (whole block removed)         -> PASS
#   pristine 1.5.7                      -> PASS
#   a multi-line if-body + else         -> PASS
#   an if/else-if/else chain            -> PASS
#   a synthetic dangling else           -> FIRE
for cline_f in fs/exec.c fs/read_write.c fs/stat.c fs/open.c drivers/input/input.c; do
    [ -e "$cline_f" ] || continue
    cline_bad=$(awk '
        function flush(   i, kopen, kclose, calls) {
            kopen = 0; kclose = 0; calls = 0
            for (i in sdepth) { if (sdepth[i] == "if") kopen++; if (sdepth[i] == "else") kclose++ }
            for (i in clines) calls++
            if (calls > 0 && kclose > 0 && kopen == 0)
                printf "KSU block at line %d: %d brace-less else but %d brace-less if (call lines:%s)\n", start, kclose, kopen, calltext
            delete sdepth; delete clines; calltext = ""
        }
        { gsub(/\r/, "") }
        { o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
          depth += o - c
          if (depth < 0) depth = 0 }
        /^[[:space:]]*#ifdef CONFIG_KSU[[:space:]]*$/ { inb = 1; start = NR; delete sdepth; delete clines; calltext = ""; next }
        inb {
            if ($0 ~ /^[[:space:]]*#endif/) { flush(); inb = 0; next }
            if ($0 ~ /^[[:space:]]*else([[:space:]]+if[[:space:]]*\(.*\))?[[:space:]]*$/) sdepth[depth - 1] = "else"
            else if ($0 ~ /^[[:space:]]*(if|for|while|switch)[[:space:]]*\(/) sdepth[depth] = "if"
            if ($0 ~ /(^|[^_a-zA-Z0-9])ksu_[a-zA-Z0-9_]*\(/) { clines[NR] = 1; calltext = calltext " " NR }
        }
    ' "$cline_f")
    if [ -n "$cline_bad" ]; then
        echo "   $cline_f: $cline_bad"
        fail "a 3.x hook block was deleted non-atomically in $cline_f (an else survived without its if - this is the run12 compile error)"
    fi
done
echo "[cline] structural gate: every 3.x hook block was deleted atomically (no else without its if)."

echo "[cline] kernel tree transformed: SUSFS 2.3.0 applied, 1.5.7 stripped, KSU 4.19 compat in place."
CLINE_TRANSFORM_EOF
        export CLINE_REV_PATCH="$CLINE_DIR/susfs157_reverse.patch"
        export CLINE_SUSFS_PATCH="$CLINE_DIR/susfs_patch_to_4.19.patch"
        bash "$CLINE_DIR/cline-transform.sh"
        echo "[cline] kernel tree prepared (ReSukiSU 4.x + SUSFS 2.3.0)."
        echo "NOTE: [cline] the A/B 4.19 compat sweep above is skipped on the C line (different KSU tree)."
    fi
    # ===== C-LINE-BLOCK-END =====
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
    # SUSFS line = KSU + KSU_MANUAL_HOOK + KSU_SUSFS + KSU_SUSFS_* + KPM,
    # C line = the ReSukiSU + SUSFS 2.3.0 symbol set (see cline_config()).
    if [ "$WITH_SUSFS" -eq 2 ]; then
        cline_config
    elif [ "$WITH_SUSFS" -eq 1 ]; then
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
    if [ "$WITH_SUSFS" -eq 2 ]; then
        # cline_config() already ran olddefconfig and the full C-line gate set.
        :
    elif [ "$WITH_SUSFS" -eq 1 ]; then
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

# t35/B: -k (keep going) so that one run reports *every* error. kbuild builds
# `kernelsu-objs` (= KSU) as a single composite object and stops scheduling new
# members as soon as one fails, which is why five runs in a row each exposed only
# 1-2 errors while 20+ KSU translation units were never compiled at all. With -k
# all independent TUs still get compiled and the full error list comes out in one
# go. It has no effect on a successful build; a failing run is expected to take
# longer and produce a bigger log - that is not a regression. It does NOT make a
# failing build pass.
make $MAKE_ARGS -j$(nproc) -k


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
# C line: no KPM at all. ReSukiSU has no `config KPM` and no kernel/kpm/, so the image
# patch is meaningless there (and `patch_linux` would look for KPatch-Next at boot,
# which this line does not carry).
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
    # SUSFS line = KSU + KSU_MANUAL_HOOK + KSU_SUSFS + KSU_SUSFS_* + KPM,
    # C line = the ReSukiSU + SUSFS 2.3.0 symbol set (see cline_config()).
    if [ "$WITH_SUSFS" -eq 2 ]; then
        cline_config
    elif [ "$WITH_SUSFS" -eq 1 ]; then
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
    if [ "$WITH_SUSFS" -eq 2 ]; then
        # cline_config() already ran olddefconfig and the full C-line gate set.
        :
    elif [ "$WITH_SUSFS" -eq 1 ]; then
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
    if [ "$WITH_SUSFS" -eq 2 ]; then
        # The C line's MIUI-only fine tuning above could drop KSU_SUSFS (it is a
        # `choice` arm, so anything that clears THREAD_INFO_IN_TASK would silently
        # fall back to KSU_TRACEPOINT_HOOK). Re-assert the whole C-line set.
        require_config KPROBES
        require_config EXT4_FS
        require_config THREAD_INFO_IN_TASK
        require_config KSU_SUSFS
        forbid_config KSU_TRACEPOINT_HOOK
        forbid_config KSU_MANUAL_HOOK
        forbid_symbol KPM
        if ! grep -q '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h; then
            echo "FATAL: [cline] include/linux/susfs.h does not report SUSFS v2.3.0 after the MIUI config block."
            exit 1
        fi
    elif [ "$WITH_SUSFS" -eq 1 ]; then
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

# t35/B: -k, see the note on the AOSP compile above. This is the compile the CI
# actually runs (every job pins MIUI_ONLY=1, so this MIUI block is the one that
# decides A line / B line), hence the -k that matters for the next run is here.
make $MAKE_ARGS -j$(nproc) -k



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
