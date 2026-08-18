# OnePlus Ace 3V Kernel Builder

Kernel builder for the OnePlus Ace 3V based on the official OnePlus kernel sources.

## Features

- KernelSU Next from the `dev` branch with dual manager signature support (Official + Custom signed manager)
- BBRv3 TCP congestion control
- FQ and CAKE queue schedulers
- ThinLTO
- Multi-Gen LRU (MGLRU)
- ZRAM with ZSTD compression
- CCache compilation acceleration
- AnyKernel3 flashable package
- Clang toolchain and CCache caching in GitHub Actions
- Weekly automated GitHub Releases with full build metadata

## Building

### GitHub Actions

- **Build OnePlus Ace 3V Kernel**: Manual workflow (`workflow_dispatch`) for testing builds and creating artifacts.
- **Weekly Release OnePlus Ace 3V Kernel**: Runs automatically every Sunday at 03:00 UTC (or manually via `workflow_dispatch`) to compile the kernel and publish a GitHub Release with detailed release notes and flashable packages.

### Local Build

```bash
./scripts/build.sh
```

Build outputs are saved in the `artifacts` directory:

- `Image`
- `Image.sha256`
- `OnePlus-Ace-3V.zip`
- `OnePlus-Ace-3V.zip.sha256`
- `release_notes.md`
- `build.log`

If the build fails, `failure.log` and any `*.rej` files are saved as well.
