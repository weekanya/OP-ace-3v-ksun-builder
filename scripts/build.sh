#!/usr/bin/env bash

set -euo pipefail

KERNEL_REPOSITORY="${KERNEL_REPOSITORY:-https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm7675.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-oneplus/sm7675_b_16.0.0_ace_3v}"
CLANG_VERSION="${CLANG_VERSION:-clang-r487747c}"
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh}"
KSU_REF="${KSU_REF:-dev}"
LOCAL_VERSION="${LOCAL_VERSION:--wee}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(dirname "$SCRIPT_DIR")}"
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE_DIR/kernel_platform/common}"
KERNEL_PLATFORM_DIR="$(dirname "$KERNEL_DIR")"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$WORKSPACE_DIR/artifacts}"
TOOLCHAIN_REPOSITORY_DIR="${TOOLCHAIN_REPOSITORY_DIR:-$WORKSPACE_DIR/toolchains/linux-x86}"
TOOLCHAIN_DIR="$TOOLCHAIN_REPOSITORY_DIR/$CLANG_VERSION"
CONFIG_FRAGMENT="${CONFIG_FRAGMENT:-$WORKSPACE_DIR/patches/kernel.config}"

install_dependencies() {
    if ! command -v apt-get >/dev/null 2>&1; then
        return
    fi

    local elevate=()
    if [ "$(id -u)" -ne 0 ]; then
        elevate=(sudo)
    fi

    "${elevate[@]}" apt-get update
    DEBIAN_FRONTEND=noninteractive "${elevate[@]}" apt-get install -y \
        bc \
        bison \
        build-essential \
        cpio \
        curl \
        device-tree-compiler \
        dwarves \
        flex \
        git \
        libelf-dev \
        libssl-dev \
        lz4 \
        python3 \
        rsync \
        xz-utils \
        zstd
}

sync_kernel() {
    if [ -d "$KERNEL_DIR/.git" ]; then
        local current_branch
        current_branch="$(git -C "$KERNEL_DIR" branch --show-current)"
        if [ "$current_branch" != "$KERNEL_BRANCH" ]; then
            printf 'Expected branch %s, found %s\n' "$KERNEL_BRANCH" "$current_branch" >&2
            exit 1
        fi
        return
    fi

    if [ -e "$KERNEL_DIR" ]; then
        printf 'Kernel path exists and is not a Git repository: %s\n' "$KERNEL_DIR" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$KERNEL_DIR")"
    git clone --depth 1 --single-branch --branch "$KERNEL_BRANCH" "$KERNEL_REPOSITORY" "$KERNEL_DIR"
}

sync_toolchain() {
    if [ -x "$TOOLCHAIN_DIR/bin/clang" ]; then
        return
    fi

    if [ ! -d "$TOOLCHAIN_REPOSITORY_DIR/.git" ]; then
        mkdir -p "$(dirname "$TOOLCHAIN_REPOSITORY_DIR")"
        git clone --depth 1 --filter=blob:none --sparse --branch main \
            https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
            "$TOOLCHAIN_REPOSITORY_DIR"
    fi

    git -C "$TOOLCHAIN_REPOSITORY_DIR" sparse-checkout set "$CLANG_VERSION"

    if [ ! -x "$TOOLCHAIN_DIR/bin/clang" ]; then
        printf 'Clang toolchain not found: %s\n' "$TOOLCHAIN_DIR" >&2
        exit 1
    fi
}

setup_kernelsu() {
    local setup_script="${RUNNER_TEMP:-/tmp}/kernelsu-next-setup.sh"
    curl --fail --location --proto '=https' "$KSU_SETUP_URL" -o "$setup_script"

    cd "$KERNEL_PLATFORM_DIR"
    bash "$setup_script" "$KSU_REF"

    if [ ! -L "$KERNEL_DIR/drivers/kernelsu" ]; then
        printf 'KernelSU Next was not integrated into the kernel tree\n' >&2
        exit 1
    fi
}

apply_config() {
    if [ ! -f "$CONFIG_FRAGMENT" ]; then
        printf 'Config fragment not found: %s\n' "$CONFIG_FRAGMENT" >&2
        exit 1
    fi

    local entry option value
    while IFS= read -r entry || [ -n "$entry" ]; do
        [ -n "$entry" ] || continue
        option="${entry%%=*}"
        value="${entry#*=}"
        option="${option#CONFIG_}"

        case "$value" in
            y) "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e "$option" ;;
            m) "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -m "$option" ;;
            n) "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d "$option" ;;
            *) "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" --set-val "$option" "$value" ;;
        esac
    done < "$CONFIG_FRAGMENT"
}

verify_config() {
    local entry
    while IFS= read -r entry || [ -n "$entry" ]; do
        [ -n "$entry" ] || continue
        if ! grep -Fxq "$entry" "$OUT_DIR/.config"; then
            printf 'Required config was not enabled: %s\n' "$entry" >&2
            exit 1
        fi
    done < "$CONFIG_FRAGMENT"

}

build_kernel() {
    mkdir -p "$OUT_DIR" "$ARTIFACTS_DIR"
    export PATH="$TOOLCHAIN_DIR/bin:$PATH"
    export ARCH=arm64
    export SUBARCH=arm64
    export LLVM=1
    export LLVM_IAS=1
    export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-wee}"
    export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-wee}"
    export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(git -C "$KERNEL_DIR" log -1 --format=%cD)}"

    : > "$KERNEL_DIR/.scmversion"

    make -C "$KERNEL_DIR" O="$OUT_DIR" gki_defconfig
    apply_config
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" --set-str LOCALVERSION "$LOCAL_VERSION"
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LOCALVERSION_AUTO
    make -C "$KERNEL_DIR" O="$OUT_DIR" olddefconfig
    verify_config
    if ! grep -Fxq "CONFIG_LOCALVERSION=\"$LOCAL_VERSION\"" "$OUT_DIR/.config"; then
        printf 'Local version was not applied: %s\n' "$LOCAL_VERSION" >&2
        exit 1
    fi
    make -C "$KERNEL_DIR" O="$OUT_DIR" -j"$(nproc --all)" Image 2>&1 | tee "$ARTIFACTS_DIR/build.log"

    local image="$OUT_DIR/arch/arm64/boot/Image"
    if [ ! -s "$image" ]; then
        printf 'Kernel Image was not produced: %s\n' "$image" >&2
        exit 1
    fi

    cp "$image" "$ARTIFACTS_DIR/Image"
    sha256sum "$ARTIFACTS_DIR/Image" | tee "$ARTIFACTS_DIR/Image.sha256"
}

install_dependencies
sync_kernel
sync_toolchain
setup_kernelsu
build_kernel
