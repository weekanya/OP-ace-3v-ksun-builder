# OnePlus Ace 3V Kernel Builder

Сборщик ядра для OnePlus Ace 3V на базе официальных исходников OnePlus.

## Что включено

- KernelSU Next из ветки `dev`
- BBRv3
- планировщики FQ и CAKE
- ThinLTO
- ZRAM с ZSTD
- сборка установочного архива AnyKernel3
- кэширование Clang в GitHub Actions

## Сборка

Сборка запускается вручную через workflow `Build OnePlus Ace 3V Kernel` в GitHub Actions.

Для локального запуска:

```bash
./scripts/build.sh
```

Готовые файлы сохраняются в каталоге `artifacts`:

- `Image`
- `Image.sha256`
- `ak3nthng-OnePlus-Ace-3V.zip`
- `ak3nthng-OnePlus-Ace-3V.zip.sha256`
- `build.log`

При ошибке сборки дополнительно сохраняются `failure.log` и найденные файлы `*.rej`.
