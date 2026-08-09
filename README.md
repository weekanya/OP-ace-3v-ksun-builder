# OnePlus Ace 3V Kernel Builder

Kernel builder for the OnePlus Ace 3V based on the official OnePlus kernel sources.

## Features

- KernelSU Next from the `dev` branch
- BBRv3
- FQ and CAKE queue schedulers
- ThinLTO
- ZRAM with ZSTD
- AnyKernel3 flashable package
- Clang caching in GitHub Actions

## Building

Run the `Build OnePlus Ace 3V Kernel` workflow manually in GitHub Actions.

For a local build:

```bash
./scripts/build.sh
```

Build outputs are saved in the `artifacts` directory:

- `Image`
- `Image.sha256`
- `ak3nthng-OnePlus-Ace-3V.zip`
- `ak3nthng-OnePlus-Ace-3V.zip.sha256`
- `build.log`

If the build fails, `failure.log` and any `*.rej` files are saved as well.
