#!/usr/bin/env bash
#
# Shadow Kernel build script
#   Device : Xiaomi miatoll (Redmi Note 9 Pro / 9S / POCO M2 Pro / ...)
#   ROM    : EvolutionX (Android 16)
#   Owner  : Vortex FR
#   Notes  : KernelSU built-in, gaming / daily / battery tuning, Clang + lld
#
# The toolchains (Clang prebuilt + AArch64/ARM GCC 4.9 binutils) are cloned
# into the kernel root on first use and reused afterwards.
#
# Usage:
#   ./build.sh              full build: compile + package AnyKernel3 zip
#   ./build.sh compile      only compile  -> out/arch/arm64/boot/Image.gz
#   ./build.sh zupload      only package  -> Shadow-Kernel-<device>-<stamp>.zip
#   ./build.sh clean        drop the out/ build dir
#
# Every knob below can be overridden from the environment, which is how the
# GitHub Actions workflow (.github/workflows/build-kernel.yml) reuses this
# exact recipe in CI instead of duplicating it:
#
#   ARCH DEFCONFIG OUT_DIR KERNEL_TARGET DEVICE_NAME TANGGAL OUT_ZIP AK_DIR
#   CLANG_REPO GCC64_REPO GCC32_REPO CLANG_DIR GCC64_DIR GCC32_DIR
#   CROSS_COMPILE CROSS_COMPILE_ARM32 SKIP_TOOLCHAIN_CLONE
#
# Examples:
#   ./build.sh                                   # stock defaults
#   DEFCONFIG=vendor/xiaomi/miatoll_defconfig ./build.sh
#   KERNEL_TARGET=Image.gz SKIP_TOOLCHAIN_CLONE=1 ./build.sh compile
#

set -o pipefail

# ---- tunables (override via environment) ----------------------------------
ARCH="${ARCH:-arm64}"
DEFCONFIG="${DEFCONFIG:-vendor/xiaomi/miatoll_defconfig}"
OUT_DIR="${OUT_DIR:-out}"
KERNEL_TARGET="${KERNEL_TARGET:-}"                  # empty -> default target
DEVICE_NAME="${DEVICE_NAME:-miatoll}"
TANGGAL="${TANGGAL:-$(date +"%Y%m%d-%H%M")}"
OUT_ZIP="${OUT_ZIP:-Shadow-Kernel-${DEVICE_NAME}-${TANGGAL}.zip}"
AK_DIR="${AK_DIR:-AnyKernel3}"                      # empty -> skip packaging

# toolchains: "<git repo>" cloned into "<dir>", detected via "<marker>"
CLANG_REPO="${CLANG_REPO:-https://github.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-6443078}"
GCC64_REPO="${GCC64_REPO:-https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9}"
GCC32_REPO="${GCC32_REPO:-https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9}"
CLANG_DIR="${CLANG_DIR:-clang}"
GCC64_DIR="${GCC64_DIR:-gcc64}"
GCC32_DIR="${GCC32_DIR:-gcc32}"
SKIP_TOOLCHAIN_CLONE="${SKIP_TOOLCHAIN_CLONE:-0}"   # 1 -> expect them on PATH

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

function compile()
{
    export LC_ALL=C
    export USE_CCACHE=1
    [ -x "$(command -v ccache)" ] && ccache -M 25G

    export ARCH
    export KBUILD_BUILD_HOST="Shadow-Kernel"
    export KBUILD_BUILD_USER="vortex_frr"

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
    export_out "outdir=$OUT_DIR"
    export_out "kernel_release=$(cat "$OUT_DIR/include/config/kernel.release" 2>/dev/null)"
    return 0
}

function zupload()
{
    local zimage="$OUT_DIR/arch/$ARCH/boot/Image.gz"

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

    # Package with the repo's branded AnyKernel3 (reuses device DTB)
    cp "$zimage" "$AK_DIR/Image.gz" || return 1
    (
        cd "$AK_DIR" || exit 1
        zip -r9 "../$OUT_ZIP" ./* -x .git/\* .gitignore
    ) || return 1

    echo -e " Built: $OUT_ZIP"
    export_out "zip=$OUT_ZIP"
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
