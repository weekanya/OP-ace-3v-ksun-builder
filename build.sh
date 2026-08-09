#!/usr/bin/env bash

set -euo pipefail

KERNEL_REPOSITORY="${KERNEL_REPOSITORY:-https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm7675.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-oneplus/sm7675_b_16.0.0_ace_3v}"
CLANG_VERSION="${CLANG_VERSION:-clang-r487747c}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$SCRIPT_DIR}"
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE_DIR/kernel_platform/common}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$WORKSPACE_DIR/artifacts}"
TOOLCHAIN_REPOSITORY_DIR="${TOOLCHAIN_REPOSITORY_DIR:-$WORKSPACE_DIR/toolchains/linux-x86}"
TOOLCHAIN_DIR="$TOOLCHAIN_REPOSITORY_DIR/$CLANG_VERSION"

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

build_kernel() {
    mkdir -p "$OUT_DIR" "$ARTIFACTS_DIR"
    export PATH="$TOOLCHAIN_DIR/bin:$PATH"
    export ARCH=arm64
    export SUBARCH=arm64
    export LLVM=1
    export LLVM_IAS=1
    export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-OnePlus}"
    export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-ace-3v}"
    export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(git -C "$KERNEL_DIR" log -1 --format=%cD)}"

    : > "$KERNEL_DIR/.scmversion"

    make -C "$KERNEL_DIR" O="$OUT_DIR" gki_defconfig
    make -C "$KERNEL_DIR" O="$OUT_DIR" olddefconfig
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
build_kernel
