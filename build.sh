#!/bin/bash
# Shadow Kernel build script
# Device : Xiaomi miatoll (Redmi Note 9 Pro / 9S / POCO M2 Pro / ...)
# ROM    : EvolutionX (Android 16)
# Owner  : Vortex FR
# Features: KernelSU built-in, gaming / daily / battery tuning
#
# Toolchains are auto-cloned on first build (Clang + AArch64/ARM GCC 4.9).

function compile()
{
    export LC_ALL=C
    export USE_CCACHE=1
    [ -x "$(command -v ccache)" ] && ccache -M 25G

    TANGGAL=$(date +"%Y%m%d-%H%M")

    export ARCH=arm64
    export KBUILD_BUILD_HOST="Shadow-Kernel"
    export KBUILD_BUILD_USER="VortexFR"

    # --- Toolchains (auto-clone if missing) ---
    clangbin=clang/bin/clang
    if ! [ -a "$clangbin" ]; then
        echo "[*] Cloning Clang prebuilt ..."
        git clone --depth=1 https://github.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-6443078 clang
    fi
    gcc64bin=gcc64/bin/aarch64-linux-android-as
    if ! [ -a "$gcc64bin" ]; then
        echo "[*] Cloning AArch64 GCC 4.9 ..."
        git clone --depth=1 https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9 gcc64
    fi
    gcc32bin=gcc32/bin/arm-linux-androideabi-as
    if ! [ -a "$gcc32bin" ]; then
        echo "[*] Cloning ARM GCC 4.9 ..."
        git clone --depth=1 https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9 gcc32
    fi

    # --- Configure (KernelSU + Shadow Kernel tuning live in this defconfig) ---
    make O=out ARCH=arm64 vendor/xiaomi/miatoll_defconfig

    # --- Build ---
    PATH="${PWD}/clang/bin:${PWD}/gcc32/bin:${PWD}/gcc64/bin:${PATH}" \
    make -j"$(nproc --all)" O=out \
        ARCH=arm64 \
        CC="clang" \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        CROSS_COMPILE="${PWD}/gcc64/bin/aarch64-linux-android-" \
        CROSS_COMPILE_ARM32="${PWD}/gcc32/bin/arm-linux-androideabi-" \
        LD=ld.lld \
        AR=llvm-ar \
        NM=llvm-nm \
        OBJCOPY=llvm-objcopy \
        OBJDUMP=llvm-objdump \
        STRIP=llvm-strip \
        CONFIG_NO_ERROR_ON_MISMATCH=y

    echo "TANGGAL=$TANGGAL" > /tmp/shadow_build.env
}

function zupload()
{
    if [ -f /tmp/shadow_build.env ]; then
        source /tmp/shadow_build.env
    else
        TANGGAL=$(date +"%Y%m%d-%H%M")
    fi

    zimage=out/arch/arm64/boot/Image.gz
    if ! [ -a "$zimage" ]; then
        echo " Failed To Compile Kernel"
        exit 1
    fi
    echo -e " Kernel Compile Successful"

    # Package with the repo's branded AnyKernel3 (reuses device DTB)
    AK=AnyKernel3
    cp "$zimage" "$AK/Image.gz"
    cd "$AK" || exit 1
    zip -r9 "../Shadow-Kernel-miatoll-${TANGGAL}.zip" ./* -x .git/\* .gitignore
    cd ../
    echo -e " Built: Shadow-Kernel-miatoll-${TANGGAL}.zip"
}

compile
zupload
