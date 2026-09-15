 ███  █   █ ████   ███   ███  █   █ █   █
█   █ ██ ██ █   █ █   █ █   █ █   █ █   █
█     █ █ █ █   █ █   █ █  ██ █   █  █ █
█     █ █ █ ████   ████ █ █ █ █████   █
█     █   █ █         █ ██  █ █   █  █ █
█   █ █   █ █         █ █   █ █   █ █   █
 ███  █   █ █      ███   ███  █   █ █   █

      ████  █   █ █   █ █████ ████
      █   █ █   █ ██  █ █     █   █
      █   █ █   █ █ █ █ █     █   █
      ████  █ █ █ █  ██ ████  ████
      █     █ █ █ █   █ █     █ █
      █     ██ ██ █   █ █     █  █
      █     █   █ █   █ █████ █   █

# CMP90HX Pwner

Инструмент для CMP 90HX с двумя независимыми действиями: установка compute unlock и ручное включение PCIe Gen2.

Главное изменение текущей версии: **Gen2 больше не запускается автоматически при загрузке системы**. После каждой перезагрузки пользователь сам запускает пункт `PCIe GEN2`. Общего пункта «compute + Gen2 сразу» больше нет.

## Главное меню

```text
1) COMPUTE UNLOCK
2) PCIe GEN2
3) VERIFY
4) INSTALL CUDA TOOLKIT
5) INSTALL 4-BEEP AT START
6) INSTALL FAN/GPU HELPERS
7) UNINSTALL
0) EXIT
```

### COMPUTE UNLOCK

Устанавливает NVIDIA 610.43.03 и существующий проверенный patched-driver path, активирует патченный драйвер и проверяет снятие вычислительных ограничений. Сам алгоритм установки драйвера из предыдущей рабочей версии не переписан.

Этот пункт не применяет маски PCIe, не делает retrain и не запускает Gen2-runner.

### PCIe GEN2

Запускается вручную. Используется проверенная последовательность из debug bundle:

```text
handoff -> adaptive minimal -> verify
         -> aggressive/reset path -> verify
         -> mandatory final soft pass -> verify
```

Для обычного и агрессивного прохода по умолчанию установлено по **13 попыток**:

```text
CMP90HX_SOFT_MASK_OPEN_TRIES=13
CMP90HX_AGGR_MASK_OPEN_TRIES=13
```

Если Gen2 не сошёлся, безопаснее перезагрузить машину и снова вручную запустить `PCIe GEN2`.

## Установка

На чистой Ubuntu Secure Boot должен быть выключен. Во время установки не подключайте монитор к CMP 90HX: `nouveau` может занять карту до установки нужного драйвера.

Можно скачать один launcher:

```bash
wget https://raw.githubusercontent.com/iatethelogs/cmp90hx_pwner/main/rejoin17.sh
chmod +x rejoin17.sh
sudo AUTO_REBOOT_IF_NOUVEAU=1 ./rejoin17.sh
```

При запуске из клонированного репозитория launcher использует локальный `lib/rejoin17-core.sh`. При одиночном `wget` он загружает этот же core из текущего `main`.

Сначала один раз выберите:

```text
1) COMPUTE UNLOCK
```

После успешной установки запускайте:

```text
2) PCIe GEN2
```

После каждой следующей перезагрузки повторно запускайте только `PCIe GEN2`.

То же самое без меню:

```bash
sudo ./rejoin17.sh --compute-unlock
sudo ./rejoin17.sh --gen2
sudo ./rejoin17.sh --verify
```

## VERIFY

Проверяет отдельно существующий compute unlock и текущее состояние PCIe link. Проверка ничего не применяет и не включает Gen2.

## Дополнительные пункты

`INSTALL CUDA TOOLKIT` — устанавливает CUDA Toolkit без замены выбранного драйвера.

`INSTALL 4-BEEP AT START` — ставит четыре коротких сигнала PC speaker при старте.

`INSTALL FAN/GPU HELPERS` — устанавливает команды:

```text
fan-100
fan-60
fan-auto
gpu-full
gpu-idle
```

`UNINSTALL` — удаляет runtime проекта, драйверные файлы и дополнительные helper-команды.

## Использованные работы

- `pearlfortune/cmpunlocker` — compute unlock, rejoin15, V67 FEAT/PLM `0x823800/0x823804`.
- `jdowning100/cmpunlocker` — rejoin16 / PCIe path, XVE/LTSSM `0x088fe8`.
- `Wh1stle05/cmp90hx` — NVIDIA 610.43.03 Linux installer и packaging патчей.

## Warning

Это низкоуровневый экспериментальный проект для CMP 90HX. Он заменяет NVIDIA kernel modules и меняет состояние PCIe/GPU во время ручного Gen2-прохода. Используйте на свой риск.

---

# CMP90HX Pwner

CMP 90HX utility with two separate actions: install the compute unlock and manually enable PCIe Gen2.

**Gen2 is no longer started automatically at boot.** Run `PCIe GEN2` manually after every reboot. There is no combined compute+Gen2 action.

```text
1) COMPUTE UNLOCK
2) PCIe GEN2
3) VERIFY
4) INSTALL CUDA TOOLKIT
5) INSTALL 4-BEEP AT START
6) INSTALL FAN/GPU HELPERS
7) UNINSTALL
0) EXIT
```

`COMPUTE UNLOCK` keeps the existing known-good driver installation path, activates the patched compute driver, and verifies the compute unlock. It does not apply PCIe masks or retrain the link.

`PCIe GEN2` uses the proven debug-bundle sequence. The default soft and aggressive mask-open limits are both 13 attempts. It is manual only; no Gen2 boot service is enabled by this front-end.

Install and run:

```bash
wget https://raw.githubusercontent.com/iatethelogs/cmp90hx_pwner/main/rejoin17.sh
chmod +x rejoin17.sh
sudo AUTO_REBOOT_IF_NOUVEAU=1 ./rejoin17.sh
```

Or use CLI actions:

```bash
sudo ./rejoin17.sh --compute-unlock
sudo ./rejoin17.sh --gen2
sudo ./rejoin17.sh --verify
```

After each reboot, run `--gen2` again if you want Gen2 active.
