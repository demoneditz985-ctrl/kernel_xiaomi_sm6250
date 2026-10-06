#!/usr/bin/env bash
#
# Shadow Kernel build script
#   Device : Xiaomi miatoll (Redmi Note 9 Pro / Pro Max / 9S / POCO M2 Pro)
#   ROM    : EvolutionX (Android 16)
#   Owner  : Vortex FR
#   Notes  : gaming / daily / battery tuning, Clang + lld
#
# The toolchains (Clang prebuilt + AArch64/ARM GCC 4.9 binutils) are cloned
# into the kernel root on first use and reused afterwards.
#
# Usage:
#   ./build.sh              full build: compile + package AnyKernel3 zip
#   ./build.sh compile      only compile  -> out/arch/arm64/boot/Image.gz
#   ./build.sh zupload      only package  -> Shadow-Kernel-<dev>-<stamp>-<variant>.zip
#   ./build.sh clean        drop the build dir
#
# Two flavours, one command apart:
#   KSU=on   (default)  KernelSU compiled in  -> root, needs the KernelSU Manager app
#   KSU=off             KernelSU compiled out -> no root at all, for users who don't want it
#   e.g.  KSU=off ./build.sh
#
# Everything is overridable from the environment, which is how the GitHub
# Actions workflow (.github/workflows/build-kernel.yml) reuses this exact
# recipe in CI instead of duplicating it:
#
#   ARCH DEFCONFIG OUT_DIR KERNEL_TARGET DEVICE_NAME TANGGAL OUT_ZIP AK_DIR KSU
#   MODSIG ROM_LOCALVERSION DEBUG
#   CLANG_REPO GCC64_REPO GCC32_REPO CLANG_DIR GCC64_DIR GCC32_DIR
#   CROSS_COMPILE CROSS_COMPILE_ARM32 SKIP_TOOLCHAIN_CLONE
#
# Replacing a ROM's boot image with a rebuilt kernel also has to keep that
# ROM's /vendor/lib/modules loadable, or the phone hangs on a black screen
# even though the kernel itself is fine. Two knobs control that:
#   MODSIG=permissive (default)  turn CONFIG_MODULE_SIG_FORCE off. Every
#                     kernel build generates its own certs/signing_key.pem, so
#                     a rebuild can never hold the key your ROM signed its
#                     .ko files with; with SIG_FORCE=y the kernel then refuses
#                     every one of them. 'keep' leaves the defconfig policy
#                     alone (only sensible when the ROM was built from THIS
#                     tree with the same key still in out/).
#   ROM_LOCALVERSION="<str>"    use exactly this as LOCALVERSION, i.e. the
#                     `uname -r` your running ROM reports, so the modules'
#                     vermagic still matches. Overrides the
#                     -ShadowKernel[-rootless] tag -> the two flavours then
#                     look identical in uname -r.
#   DEBUG=on                     KSU_DEBUG=y (root builds only) + earlycon and
#                     loglevel=8 on the kernel cmdline, so a hang before the
#                     real console registers still produces output.
#

set -o pipefail

# ---- tunables (override via environment) ----------------------------------
ARCH="${ARCH:-arm64}"
DEFCONFIG="${DEFCONFIG:-vendor/xiaomi/miatoll_defconfig}"
OUT_DIR="${OUT_DIR:-out}"
KERNEL_TARGET="${KERNEL_TARGET:-}"                  # empty -> default target
DEVICE_NAME="${DEVICE_NAME:-miatoll}"
TANGGAL="${TANGGAL:-$(date +"%Y%m%d-%H%M")}"
AK_DIR="${AK_DIR:-AnyKernel3}"                      # empty -> skip packaging
KSU="${KSU:-on}"                                    # on -> KernelSU | off -> rootless
MODSIG="${MODSIG:-permissive}"                      # permissive | keep  (module signatures)
ROM_LOCALVERSION="${ROM_LOCALVERSION:-}"            # exact uname -r to match ROM module vermagic
DEBUG="${DEBUG:-off}"                               # on -> KSU_DEBUG + earlycon

# toolchains: "<git repo>" cloned into "<dir>", detected via "<marker>"
CLANG_REPO="${CLANG_REPO:-https://github.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-6443078}"
GCC64_REPO="${GCC64_REPO:-https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9}"
GCC32_REPO="${GCC32_REPO:-https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9}"
CLANG_DIR="${CLANG_DIR:-clang}"
GCC64_DIR="${GCC64_DIR:-gcc64}"
GCC32_DIR="${GCC32_DIR:-gcc32}"
SKIP_TOOLCHAIN_CLONE="${SKIP_TOOLCHAIN_CLONE:-0}"  # 1 -> expect them on PATH

# ---- variant ---------------------------------------------------------------
# KernelSU only reaches the rest of the tree through drivers/Makefile's
# obj-$(CONFIG_KSU), so compiling it out entirely is clean - no dangling refs.
case "$KSU" in
    on|y|yes|1)
        KSU_WANT=1;  VARIANT="ksu"
        VARIANT_LABEL="KernelSU (root) - flash KernelSU Manager for su"
        LOCAL_VERSION="-ShadowKernel" ;;
    off|n|no|0)
        KSU_WANT=0;  VARIANT="rootless"
        VARIANT_LABEL="Rootless - no KernelSU, no su, nothing to manage"
        LOCAL_VERSION="-ShadowKernel-rootless" ;;
    *)
        echo "[!] KSU must be 'on' or 'off' (got: $KSU)" >&2
        exit 1 ;;
esac

# ---- module-compat + debug policy ------------------------------------------
# Both of these are asserted again against the *final* .config in compile(),
# because a silently-ignored toggle is exactly how a black-screen build ships.
case "$MODSIG" in
    permissive|"") MODSIG_WANT=0 ;;   # 0 -> do NOT force module signatures
    keep)          MODSIG_WANT=1 ;;
    *)
        echo "[!] MODSIG must be 'permissive' or 'keep' (got: $MODSIG)" >&2
        exit 1 ;;
esac
case "$DEBUG" in
    on|y|yes|1) DEBUG_WANT=1 ;;
    off|n|no|0|"") DEBUG_WANT=0 ;;
    *)
        echo "[!] DEBUG must be 'on' or 'off' (got: $DEBUG)" >&2
        exit 1 ;;
esac
OUT_ZIP="${OUT_ZIP:-Shadow-Kernel-${DEVICE_NAME}-${TANGGAL}-${VARIANT}.zip}"

# --- stay in the kernel root, everything above is relative to it -----------
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit 1

usage()
{
    sed -n '/^# Usage:/,/^[^#]/p' "$SELF" | sed 's/^#\{1,2\} \{0,1\}//' | sed '$d'
}

# hand results to the Actions workflow so it can name/verify the artifacts
export_out()
{
    [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
    return 0
}

fetch_toolchain()
{
    # $1 = checkout dir, $2 = repo url, $3 = marker executable inside it
    if [ -x "$1/$3" ]; then
        echo "[*] Reusing toolchain in $1/"
        return 0
    fi
    if [ "$SKIP_TOOLCHAIN_CLONE" = "1" ]; then
        echo "[*] SKIP_TOOLCHAIN_CLONE=1 -> expecting $(basename "$2") on PATH"
        return 0
    fi
    echo "[*] Cloning $(basename "$2") -> $1/ ..."
    git clone --depth=1 "$2" "$1"
}

# read a property out of the AnyKernel3 script (same parser the flasher uses)
akprop()
{
    local file="${AK_DIR:-AnyKernel3}/anykernel.sh" val=
    [ -f "$file" ] || return 0
    val="$(grep "^$1=" "$file" | tail -n1 | cut -d= -f2-)"
    printf '%s' "$val"
}

function compile()
{
    export LC_ALL=C
    export USE_CCACHE=1
    [ -x "$(command -v ccache)" ] && ccache -M 25G

    export ARCH
    export KBUILD_BUILD_HOST="Shadow-Kernel"
    export KBUILD_BUILD_USER="vortex_frr"

    echo "[*] Variant: $VARIANT ($VARIANT_LABEL)"

    # --- Toolchains (auto-clone if missing) ---
    fetch_toolchain "$CLANG_DIR" "$CLANG_REPO" "bin/clang" || return 1
    fetch_toolchain "$GCC64_DIR" "$GCC64_REPO" "bin/aarch64-linux-android-as" || return 1
    fetch_toolchain "$GCC32_DIR" "$GCC32_REPO" "bin/arm-linux-androideabi-as" || return 1

    # ld.lld / llvm-ar / ... come from the Clang prebuilt's bin dir
    export PATH="$PWD/$CLANG_DIR/bin:$PWD/$GCC32_DIR/bin:$PWD/$GCC64_DIR/bin:$PATH"

    local cross64="${CROSS_COMPILE:-$PWD/$GCC64_DIR/bin/aarch64-linux-android-}"
    local cross32="${CROSS_COMPILE_ARM32:-$PWD/$GCC32_DIR/bin/arm-linux-androideabi-}"

    # --- Configure (KernelSU + Shadow Kernel tuning live in this defconfig) ---
    if ! [ -f "arch/$ARCH/configs/$DEFCONFIG" ]; then
        echo "[!] No defconfig at arch/$ARCH/configs/$DEFCONFIG"
        return 1
    fi
    make O="$OUT_DIR" ARCH="$ARCH" "$DEFCONFIG" || return 1

    # --- vermagic: whatever uname -r ends up being is also the string every
    #     prebuilt .ko has to agree with, so a ROM-localised build must be able
    #     to pin it instead of arguing with the vendor modules ---
    if [ -n "$ROM_LOCALVERSION" ]; then
        echo "[*] LOCALVERSION forced to '$ROM_LOCALVERSION' (matching the ROM's modules)"
        echo "[!] in this mode uname -r no longer tells the two flavours apart" >&2
        LOCAL_VERSION="$ROM_LOCALVERSION"
    fi

    # --- Variant switch: drop KernelSU and mark the build so uname -r tells
    #     the two flavours apart once booted. (drivers/kernelsu/Kconfig defines
    #     only KSU and KSU_DEBUG; the KSU_DISABLE_* lines some defconfigs carry
    #     are leftovers that olddefconfig discards, so they are not touched.) ---
    ./scripts/config --file "$OUT_DIR/.config" \
        --set-str LOCALVERSION "$LOCAL_VERSION" || return 1
    if [ "$KSU_WANT" = "0" ]; then
        ./scripts/config --file "$OUT_DIR/.config" \
            --disable KSU --disable KSU_DEBUG || return 1
    fi

    # --- module signatures. certs/signing_key.pem is generated per build and
    #     is not in the tree, so this kernel's key can never be the key your
    #     ROM signed /vendor/lib/modules with. With MODULE_SIG_FORCE=y those
    #     modules are refused -> display/audio never come up -> bootloop.
    #     MODULE_SIG stays on, so signature checks still happen when a module
    #     does carry one; only the hard requirement goes away. ---
    if [ "$MODSIG_WANT" = "0" ]; then
        ./scripts/config --file "$OUT_DIR/.config" \
            --disable MODULE_SIG_FORCE || return 1
    else
        echo "[*] MODSIG=keep -> leaving CONFIG_MODULE_SIG_FORCE as the defconfig sets it"
    fi

    # --- debug build: KSU's own pr_info stream + early output on the console.
    #     arm64 4.14 has no EARLY_PRINTK symbol, so earlycon goes on the
    #     cmdline (CONFIG_CMDLINE_EXTEND=y here, so the bootloader's own
    #     androidboot args still win and this is purely additive) ---
    if [ "$DEBUG_WANT" = "1" ]; then
        if [ "$KSU_WANT" = "1" ]; then
            ./scripts/config --file "$OUT_DIR/.config" --enable KSU_DEBUG || return 1
        else
            echo "[*] DEBUG=on with KSU=off -> KSU_DEBUG skipped, nothing to debug"
        fi
        local base_cmdline
        # strip BOTH quotes - `cut -d'"' -f2-` would keep the trailing one and
        # --set-str would then wrap the whole thing again
        base_cmdline="$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$OUT_DIR/.config" | tail -n1)"
        case "$base_cmdline" in
            *earlycon*) echo "[*] earlycon already on the cmdline" ;;
            *)  ./scripts/config --file "$OUT_DIR/.config" \
                    --set-str CMDLINE "${base_cmdline:+$base_cmdline }earlycon loglevel=8" \
                    || return 1 ;;
        esac
    fi

    make O="$OUT_DIR" ARCH="$ARCH" olddefconfig >/dev/null || return 1

    # the toggles above have to survive olddefconfig, or they did nothing
    if [ "$MODSIG_WANT" = "0" ] && grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$OUT_DIR/.config"; then
        echo "[!] MODSIG=permissive but CONFIG_MODULE_SIG_FORCE=y survived olddefconfig" >&2
        echo "    -> your ROM's modules would be refused; refusing to ship that build" >&2
        return 1
    fi
    if [ "$DEBUG_WANT" = "1" ] && [ "$KSU_WANT" = "1" ] \
       && ! grep -q '^CONFIG_KSU_DEBUG=y' "$OUT_DIR/.config"; then
        echo "[!] DEBUG=on but CONFIG_KSU_DEBUG is not enabled" >&2
        return 1
    fi
    if grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$OUT_DIR/.config"; then
        echo "[*] module signatures: FORCED (only right if the ROM shares this key)"
    else
        echo "[*] module signatures: not forced -> the ROM's prebuilt .ko files load"
    fi

    if grep -q "^CONFIG_KSU=y$" "$OUT_DIR/.config"; then
        [ "$KSU_WANT" = "1" ] || { echo "[!] asked for rootless but CONFIG_KSU is still on"; return 1; }
        echo "[*] CONFIG_KSU=y  -> root variant"
    else
        [ "$KSU_WANT" = "0" ] || { echo "[!] CONFIG_KSU is missing from $OUT_DIR/.config"; return 1; }
        echo "[*] CONFIG_KSU is off -> rootless variant"
    fi

    # --- Build ---
    make -j"$(nproc --all)" O="$OUT_DIR" \
        ARCH="$ARCH" \
        CC="clang" \
        CLANG_TRIPLE="aarch64-linux-gnu-" \
        CROSS_COMPILE="$cross64" \
        CROSS_COMPILE_ARM32="$cross32" \
        LD=ld.lld \
        AR=llvm-ar \
        NM=llvm-nm \
        OBJCOPY=llvm-objcopy \
        OBJDUMP=llvm-objdump \
        STRIP=llvm-strip \
        CONFIG_NO_ERROR_ON_MISMATCH=y \
        $KERNEL_TARGET || return 1

    echo "TANGGAL=$TANGGAL" > /tmp/shadow_build.env 2>/dev/null || true
    export_out "stamp=$TANGGAL"
    export_out "variant=$VARIANT"
    export_out "outdir=$OUT_DIR"
    export_out "kernel_release=$(cat "$OUT_DIR/include/config/kernel.release" 2>/dev/null)"
    return 0
}

# fill the per-build info the flasher prints from the zip's "version" file
write_version_file()
{
    local dir="$1" krel ccver sha boards android modsig
    # what the kernel will accept from /vendor/lib/modules - worth showing at
    # flash time, because "modules refused" is what a black screen after a
    # kernel swap usually turns out to be
    if [ -f "$OUT_DIR/.config" ]; then
        if grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$OUT_DIR/.config"; then
            modsig="enforced"
        else
            modsig="not enforced"
        fi
    else
        case "$MODSIG_WANT" in
            0) modsig="not enforced" ;;
            *) modsig="whatever the defconfig says" ;;
        esac
    fi
    krel="$(cat "$OUT_DIR/include/config/kernel.release" 2>/dev/null || echo unknown)"
    ccver="$("$CLANG_DIR/bin/clang" --version 2>/dev/null | grep -oE 'clang version [0-9.]+' | head -1)"
    [ "$ccver" ] || ccver="$(command -v clang >/dev/null && clang --version | grep -oE 'clang version [0-9.]+' | head -1 || echo unknown)"
    sha="$(git rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"
    boards="$(grep -oE '^device\.name[0-9]+=.*' "$AK_DIR/anykernel.sh" 2>/dev/null | cut -d= -f2- | tr '\n' ' ')"
    android="$(akprop supported.versions)"

    {
        printf ' Kernel    : %s\n' "$krel"
        printf ' Variant   : %s\n' "$VARIANT_LABEL"
        printf ' Compiler  : %s\n' "$ccver"
        printf ' Built     : %s UTC\n' "$(date -u +"%Y-%m-%d %H:%M")"
        printf ' Commit    : %s\n' "$sha"
        printf ' Modules   : signatures %s\n' "$modsig"
        [ "$DEBUG_WANT" = "1" ] && printf ' Debug     : earlycon + KSU_DEBUG on\n'
        [ "$boards" ]  && printf ' For       : %s\n' "${boards% }"
        [ "$android" ] && printf ' Android   : %s\n' "$android"
    } > "$dir/version"
}

function zupload()
{
    local zimage="$OUT_DIR/arch/$ARCH/boot/Image.gz"
    local root="$PWD"
    local akbuild="$OUT_DIR/anykernel-$VARIANT"

    if ! [ -a "$zimage" ]; then
        echo " Failed To Compile Kernel"
        exit 1
    fi
    echo -e " Kernel Compile Successful"

    if [ -z "$AK_DIR" ]; then
        echo "[*] AK_DIR is empty -> skipping AnyKernel3 packaging"
        export_out "zip="
        return 0
    fi

    # Build the flashable tree in out/ so the repo stays clean and both
    # variants can be packaged side by side (reuses device DTB via AK3)
    rm -rf "$akbuild"
    mkdir -p "$akbuild"
    cp -a "$AK_DIR/." "$akbuild/" || return 1
    cp "$zimage" "$akbuild/Image.gz" || return 1
    write_version_file "$akbuild"

    # stamp the variant into the properties the flasher displays
    local krel
    krel="$(cat "$OUT_DIR/include/config/kernel.release" 2>/dev/null || echo unknown)"
    sed -i \
        -e "s#^kernel.version=.*#kernel.version=Shadow Kernel $krel [$VARIANT]#" \
        -e "s#^message.word=.*#message.word=Shadow Kernel $krel - $VARIANT_LABEL#" \
        "$akbuild/anykernel.sh" || return 1
    grep -q '^kernel.for=' "$akbuild/anykernel.sh" \
        || printf 'kernel.for=%s\n' "$(grep -oE '^device\.name[0-9]+=.*' "$akbuild/anykernel.sh" | cut -d= -f2- | tr '\n' ' ' | sed 's/ *$//')" >> "$akbuild/anykernel.sh"
    grep -q '^build.date=' "$akbuild/anykernel.sh" \
        || printf 'build.date=%s\n' "$TANGGAL" >> "$akbuild/anykernel.sh"

    (
        cd "$akbuild" || exit 1
        zip -r9 "$root/$OUT_ZIP" ./* -x .git/\* .gitignore
    ) || return 1

    echo -e " Built: $OUT_ZIP"
    export_out "zip=$OUT_ZIP"
    export_out "variant=$VARIANT"
    export_out "stamp=$TANGGAL"
    return 0
}

case "${1:-all}" in
    all|build)        compile && zupload ;;
    compile|make)     compile ;;
    zupload|package)  zupload ;;
    clean)            rm -rf "$OUT_DIR" && echo "[*] cleaned $OUT_DIR/" ;;
    -h|--help|help)   usage ;;
    *)                echo "[!] Unknown target: $1" >&2; usage; exit 1 ;;
esac
