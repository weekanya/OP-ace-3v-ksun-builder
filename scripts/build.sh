#!/usr/bin/env bash

set -euo pipefail

KERNEL_REPOSITORY="${KERNEL_REPOSITORY:-https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm7675.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-oneplus/sm7675_b_16.0.0_ace_3v}"
ONEPLUS_REPOSITORY="${ONEPLUS_REPOSITORY:-https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm7675.git}"
ANYKERNEL_REPOSITORY="${ANYKERNEL_REPOSITORY:-https://github.com/nothing-users/AnyKernel3-Nothing.git}"
ANYKERNEL_BRANCH="${ANYKERNEL_BRANCH:-dontdelete}"
CLANG_VERSION="${CLANG_VERSION:-clang-r487747c}"
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh}"
KSU_REF="${KSU_REF:-dev}"
LOCAL_VERSION="${LOCAL_VERSION:--wee}"
USE_CCACHE="${USE_CCACHE:-1}"
CCACHE_DIR="${CCACHE_DIR:-$WORKSPACE_DIR/.ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(dirname "$SCRIPT_DIR")}"
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE_DIR/kernel_platform/common}"
KERNEL_PLATFORM_DIR="$(dirname "$KERNEL_DIR")"
ONEPLUS_SOURCE_DIR="${ONEPLUS_SOURCE_DIR:-$WORKSPACE_DIR/oneplus-source}"
ANYKERNEL_DIR="${ANYKERNEL_DIR:-$WORKSPACE_DIR/AnyKernel3}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$WORKSPACE_DIR/artifacts}"
TOOLCHAIN_REPOSITORY_DIR="${TOOLCHAIN_REPOSITORY_DIR:-$WORKSPACE_DIR/toolchains/linux-x86}"
TOOLCHAIN_DIR="$TOOLCHAIN_REPOSITORY_DIR/$CLANG_VERSION"
CONFIG_FRAGMENT="${CONFIG_FRAGMENT:-$WORKSPACE_DIR/patches/kernel.config}"
BBRV3_PATCH="${BBRV3_PATCH:-$WORKSPACE_DIR/patches/bbrv3/0001-net-tcp-backport-BBRv3-to-android14-6.1.patch}"

report_failure() {
    local status="$1"
    local reject relative destination
    local found=0
    local failure_report="$ARTIFACTS_DIR/failure.log"

    trap - EXIT
    if [ "$status" -eq 0 ]; then
        exit 0
    fi

    mkdir -p "$ARTIFACTS_DIR/rejects"
    printf 'Build failed with exit code %s\n' "$status" > "$failure_report"

    while IFS= read -r -d '' reject; do
        found=1
        relative="${reject#"$WORKSPACE_DIR/"}"
        destination="$ARTIFACTS_DIR/rejects/$relative"
        mkdir -p "$(dirname "$destination")"
        cp "$reject" "$destination"
        printf '\n===== %s =====\n' "$relative" >> "$failure_report"
        cat "$reject" >> "$failure_report"
    done < <(find "$WORKSPACE_DIR" \
        \( -path "$WORKSPACE_DIR/.git" -o -path "$ARTIFACTS_DIR" \) -prune -o \
        -type f -name '*.rej' -print0)

    if [ "$found" -eq 0 ]; then
        printf 'No .rej files found.\n' >> "$failure_report"
    fi

    cat "$failure_report" >&2
    exit "$status"
}

trap 'report_failure "$?"' EXIT

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
        ccache \
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
        zip \
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

sync_oneplus_vendor() {
    if [ ! -d "$ONEPLUS_SOURCE_DIR/.git" ]; then
        git clone --depth 1 --filter=blob:none --sparse --single-branch \
            --branch "$KERNEL_BRANCH" "$ONEPLUS_REPOSITORY" "$ONEPLUS_SOURCE_DIR"
    fi

    git -C "$ONEPLUS_SOURCE_DIR" sparse-checkout set \
        vendor/oplus/kernel/cpu \
        vendor/oplus/kernel/synchronize \
        vendor/oplus/kernel/storage \
        vendor/oplus/kernel/oplus_performance_5.10/oplus_resctrl

    if [ -L "$WORKSPACE_DIR/vendor" ]; then
        if [ "$(readlink -f "$WORKSPACE_DIR/vendor")" != "$(readlink -f "$ONEPLUS_SOURCE_DIR/vendor")" ]; then
            printf 'Vendor symlink points to an unexpected location: %s\n' "$WORKSPACE_DIR/vendor" >&2
            exit 1
        fi
        return
    fi
    if [ -e "$WORKSPACE_DIR/vendor" ]; then
        printf 'Vendor path exists and is not a symlink: %s\n' "$WORKSPACE_DIR/vendor" >&2
        exit 1
    fi

    ln -s "$ONEPLUS_SOURCE_DIR/vendor" "$WORKSPACE_DIR/vendor"
}

sync_toolchain() {
    if [ -x "$TOOLCHAIN_DIR/bin/clang" ]; then
        return
    fi

    if [ ! -d "$TOOLCHAIN_REPOSITORY_DIR/.git" ]; then
        mkdir -p "$(dirname "$TOOLCHAIN_REPOSITORY_DIR")"
        git clone --depth 1 --filter=blob:none --sparse \
            --branch android-14.0.0_r18 \
            https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
            "$TOOLCHAIN_REPOSITORY_DIR"
    fi

    git -C "$TOOLCHAIN_REPOSITORY_DIR" sparse-checkout set "$CLANG_VERSION"

    if [ ! -x "$TOOLCHAIN_DIR/bin/clang" ]; then
        printf 'Clang toolchain not found: %s\n' "$TOOLCHAIN_DIR" >&2
        exit 1
    fi
}

sync_anykernel() {
    if [ -d "$ANYKERNEL_DIR/.git" ]; then
        local current_branch
        current_branch="$(git -C "$ANYKERNEL_DIR" branch --show-current)"
        if [ "$current_branch" != "$ANYKERNEL_BRANCH" ]; then
            printf 'Expected AnyKernel3 branch %s, found %s\n' "$ANYKERNEL_BRANCH" "$current_branch" >&2
            exit 1
        fi
        git -C "$ANYKERNEL_DIR" pull --ff-only origin "$ANYKERNEL_BRANCH"
        printf 'Using AnyKernel3 commit: %s\n' "$(git -C "$ANYKERNEL_DIR" rev-parse --short HEAD)"
        return
    fi

    if [ -e "$ANYKERNEL_DIR" ]; then
        printf 'AnyKernel3 path exists and is not a Git repository: %s\n' "$ANYKERNEL_DIR" >&2
        exit 1
    fi

    git clone --depth 1 --single-branch --branch "$ANYKERNEL_BRANCH" \
        "$ANYKERNEL_REPOSITORY" "$ANYKERNEL_DIR"
    printf 'Using AnyKernel3 commit: %s\n' "$(git -C "$ANYKERNEL_DIR" rev-parse --short HEAD)"
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

apply_patches() {
    if [ ! -f "$BBRV3_PATCH" ]; then
        printf 'BBRv3 patch not found: %s\n' "$BBRV3_PATCH" >&2
        exit 1
    fi

    cd "$KERNEL_DIR"
    if git apply --reverse --check "$BBRV3_PATCH" >/dev/null 2>&1; then
        printf 'BBRv3 patch is already applied\n'
        return
    fi

    git apply --check "$BBRV3_PATCH"
    git apply "$BBRV3_PATCH"
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
    local entry option value
    while IFS= read -r entry || [ -n "$entry" ]; do
        [ -n "$entry" ] || continue
        option="${entry%%=*}"
        value="${entry#*=}"
        if [ "$value" = n ]; then
            if grep -q "^${option}=" "$OUT_DIR/.config"; then
                printf 'Required config was not disabled: %s\n' "$entry" >&2
                exit 1
            fi
            continue
        fi
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

    local make_extra_args=()
    if [ "$USE_CCACHE" = "1" ] && command -v ccache >/dev/null 2>&1; then
        export CCACHE_DIR="$CCACHE_DIR"
        export CCACHE_MAXSIZE="$CCACHE_MAXSIZE"
        export CCACHE_COMPRESS=1
        mkdir -p "$CCACHE_DIR"
        ccache -M "$CCACHE_MAXSIZE" >/dev/null 2>&1 || true
        ccache -z >/dev/null 2>&1 || true
        printf 'CCache enabled (dir: %s, max size: %s)\n' "$CCACHE_DIR" "$CCACHE_MAXSIZE"
        make_extra_args+=(CC="ccache clang" HOSTCC="ccache clang")
    fi

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
    make -C "$KERNEL_DIR" O="$OUT_DIR" -j"$(nproc --all)" "${make_extra_args[@]}" Image 2>&1 | tee "$ARTIFACTS_DIR/build.log"

    if [ "$USE_CCACHE" = "1" ] && command -v ccache >/dev/null 2>&1; then
        printf '\n--- CCache Statistics ---\n'
        ccache -s || true
    fi

    local image="$OUT_DIR/arch/arm64/boot/Image"
    if [ ! -s "$image" ]; then
        printf 'Kernel Image was not produced: %s\n' "$image" >&2
        exit 1
    fi

    cp "$image" "$ARTIFACTS_DIR/Image"
    sha256sum "$ARTIFACTS_DIR/Image" | tee "$ARTIFACTS_DIR/Image.sha256"
}

package_anykernel() {
    local image="$ARTIFACTS_DIR/Image"
    local package="$ARTIFACTS_DIR/OnePlus-Ace-3V.zip"

    if [ ! -s "$image" ]; then
        printf 'Kernel Image is missing: %s\n' "$image" >&2
        exit 1
    fi

    git -C "$ANYKERNEL_DIR" archive --format=zip --output="$package" HEAD
    zip -j "$package" "$image"
    sha256sum "$package" | tee "$package.sha256"
}

generate_release_notes() {
    local notes="$ARTIFACTS_DIR/release_notes.md"
    local image="$ARTIFACTS_DIR/Image"
    local package="$ARTIFACTS_DIR/OnePlus-Ace-3V.zip"
    local build_time
    build_time="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

    local kernel_ver="6.1"
    if [ -f "$OUT_DIR/include/config/kernel.release" ]; then
        kernel_ver="$(cat "$OUT_DIR/include/config/kernel.release")"
    elif command -v make >/dev/null 2>&1; then
        kernel_ver="$(make -s -C "$KERNEL_DIR" O="$OUT_DIR" kernelrelease 2>/dev/null || echo "6.1")"
    fi

    local kernel_commit="unknown"
    local kernel_commit_msg=""
    if [ -d "$KERNEL_DIR/.git" ]; then
        kernel_commit="$(git -C "$KERNEL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
        kernel_commit_msg="$(git -C "$KERNEL_DIR" log -1 --pretty=format:"%s" 2>/dev/null || echo "")"
    fi

    local ksu_commit="unknown"
    local ksu_desc="$KSU_REF"
    local target_ksu_dir=""
    if [ -d "$KERNEL_PLATFORM_DIR/KernelSU-Next/.git" ]; then
        target_ksu_dir="$KERNEL_PLATFORM_DIR/KernelSU-Next"
    elif [ -d "$KERNEL_DIR/drivers/kernelsu/.git" ] || [ -f "$KERNEL_DIR/drivers/kernelsu/.git" ]; then
        target_ksu_dir="$KERNEL_DIR/drivers/kernelsu"
    fi

    if [ -n "$target_ksu_dir" ]; then
        ksu_commit="$(git -C "$target_ksu_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
        ksu_desc="$(git -C "$target_ksu_dir" describe --tags --always 2>/dev/null || echo "$KSU_REF")"
    fi

    local clang_info="$CLANG_VERSION"
    if [ -x "$TOOLCHAIN_DIR/bin/clang" ]; then
        clang_info="$("$TOOLCHAIN_DIR/bin/clang" --version 2>/dev/null | head -n 1 || echo "$CLANG_VERSION")"
    fi

    local zip_hash="N/A"
    local image_hash="N/A"
    [ -f "$package.sha256" ] && zip_hash="$(awk '{print $1}' "$package.sha256")"
    [ -f "$image.sha256" ] && image_hash="$(awk '{print $1}' "$image.sha256")"

    cat <<EOF > "$notes"
# OnePlus Ace 3V Kernel Release

Custom Linux GKI kernel for **OnePlus Ace 3V** (\`SM7675\` / \`PJF110\`).

## 📋 Build Information

| Component | Details |
| :--- | :--- |
| **Linux Kernel Release** | \`$kernel_ver\` |
| **Base Kernel Branch** | [\`$KERNEL_BRANCH\`]($KERNEL_REPOSITORY) (\`$kernel_commit\`) |
| **Base Commit Message** | \`$kernel_commit_msg\` |
| **KernelSU Next** | Branch/Ref: \`$KSU_REF\` \| Version/Commit: \`$ksu_desc\` (\`$ksu_commit\`) |
| **Compiler Toolchain** | \`$clang_info\` |
| **Local Version** | \`$LOCAL_VERSION\` |
| **Build Timestamp** | \`$build_time\` |

## ✨ Features & Optimizations

- 🛡️ **KernelSU Next**: Integrated from \`$KSU_REF\` branch with support for root and GKI modules.
- 🚀 **TCP BBRv3**: Backported Google BBRv3 congestion control for high throughput and minimal latency.
- 🌐 **Queue Schedulers**: **FQ** and **CAKE** queue disciplines enabled.
- ⚡ **ZRAM + ZSTD**: Swap memory compression via Zstandard for fast paging and high compression ratio.
- 🧠 **Multi-Gen LRU (MGLRU)**: \`CONFIG_LRU_GEN=y\` for optimized memory reclamation.
- ⚙️ **ThinLTO**: Clang Thin Link-Time Optimization enabled.
- 📦 **AnyKernel3**: Flashable zip package for Recovery / Kernel Flasher.

## 📦 Files & Checksums

| File | SHA-256 Checksum |
| :--- | :--- |
| \`OnePlus-Ace-3V.zip\` | \`$zip_hash\` |
| \`Image\` | \`$image_hash\` |

## 📲 Installation

1. Download **\`OnePlus-Ace-3V.zip\`**.
2. Flash the zip via **Kernel Flasher** app (recommended) or custom recovery (TWRP/OrangeFox).
3. Reboot device.
4. Install the latest [KernelSU Next Manager APK](https://github.com/KernelSU-Next/KernelSU-Next/releases).
EOF

    printf 'Release notes generated at: %s\n' "$notes"
}

if [ "${1:-}" = sync-toolchain ]; then
    sync_toolchain
    exit 0
fi

install_dependencies
sync_kernel
sync_oneplus_vendor
sync_toolchain
setup_kernelsu
apply_patches
build_kernel
sync_anykernel
package_anykernel
generate_release_notes

