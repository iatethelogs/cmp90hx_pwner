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

При обычном запуске `rejoin17.sh` сам открывает `tmux` и делит окно на две панели: слева интерфейс и прогресс, справа подробный живой лог команд. Отдельный launcher/core больше не используется и в начале работы скрипт не скачивает никакой вспомогательный `rejoin17-core.sh`.

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

После перезагрузки `cmp90hx-compute.service` выполняет только существующую инициализацию драйвера: штатный → патченный. Это необходимо, поскольку установленный драйвер блокирует автоматическую загрузку NVIDIA через udev. Сервис не запускает Gen2-runner. Оставшаяся от прерванного ручного прохода команда записи удаляется перед инициализацией.

Установка старого Gen2-сервиса исключена из вызываемого установщика до его запуска. Сборка, патчи, установка модулей и проверки compute сохранены.

### PCIe GEN2

Запускается вручную. Полный механизм взят из `root-scripts/cmp90hx-gen2-exact-worked.sh` архива `cmp90hx-debug-bundle-20260916-002951` и встроен в единственный основной файл `rejoin17.sh` вместе с архивными зависимостями.

Порядок выполнения:

1. Проверка состояния и полный хороший способ из `exact-worked`. Карты, уже работающие на Gen2, пропускают адресную обработку FEAT.
2. Для выбранной карты сохраняются четыре FEAT-цикла из исходника: принудительная выгрузка NVIDIA, PCI reset карты, rescan, ожидание устройства, настоящий handoff штатного драйвера в патченный, настоящий `rejoin16-cycle.sh`, чтение маски и retrain. Подготовка заново выполняется перед каждым FEAT-циклом.
3. После FEAT каждой карты выполняются исходные глобальный агрессивный XVE-проход и мягкий проход. Затем сохраняются финальный глобальный агрессивный проход и до трёх мягких проходов из `exact-worked`.
4. Только если этот способ не помог всем картам — отдельный hard-FEAT механизм из предыдущей работы. Он выбирает оставшиеся без Gen2 карты с закрытой FEAT и повторно проверяет каждую непосредственно перед обработкой. После выгрузки NVIDIA, сброса выбранной карты, rescan и handoff запускаются до **13 новых записей FEAT после сброса** через настоящий `rejoin16-cycle.sh`, с проверкой и retrain. Завершают обработку агрессивный XVE и мягкий проход. Этот блок перенесён из сохранённого `rejoin17_short.sh`; его функции изолированы, исходные функции `exact-worked` сохранены.

Адресные сбросы применяются к неподдавшимся картам. Выгрузка NVIDIA, агрессивные XVE и мягкие проходы затрагивают весь набор карт — эта логика исходника сохранена.

Лимиты мягкого и агрессивного проходов фиксированы на 13. `CMP90HX_FEAT_CYCLES` по умолчанию равен 4, `CMP90HX_SOFT_ROUNDS` — 3, `CMP90HX_TOTAL_TIMEOUT` — 3600 секунд. Время проверяется между этапами, а не принудительным прерыванием команды сброса или загрузки драйвера.

При неудаче программа предлагает перезагрузить сервер и повторить `PCIe GEN2`: результат зависит от состояния карт после загрузки. Перезагрузка автоматически не запускается. Сообщение и подробный лог остаются в двух панелях tmux; Enter возвращает в меню, в том числе при запуске через `--gen2`.

## Установка

На чистой Ubuntu Secure Boot должен быть выключен. Во время установки не подключайте монитор к CMP 90HX: `nouveau` может занять карту до установки нужного драйвера.

Скачайте один скрипт:

```bash
wget https://raw.githubusercontent.com/iatethelogs/cmp90hx_pwner/main/rejoin17.sh
chmod +x rejoin17.sh
sudo AUTO_REBOOT_IF_NOUVEAU=1 ./rejoin17.sh
```

Если `tmux` ещё не установлен, скрипт установит его перед созданием двухпанельного интерфейса. Если `tmux` уже установлен, до появления интерфейса ничего дополнительно не скачивается.

Сначала один раз выберите:

```text
1) COMPUTE UNLOCK
```

После успешной установки запускайте:

```text
2) PCIe GEN2
```

После каждой следующей перезагрузки повторно запускайте только `PCIe GEN2`.

То же самое без выбора пункта меню:

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

On normal startup, `rejoin17.sh` launches `tmux` itself and splits the terminal into two panes: UI/progress on the left and the live detailed command log on the right. There is no separate launcher/core download at startup.

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

`COMPUTE UNLOCK` keeps the existing known-good driver installation path, activates the patched compute driver, and verifies the compute unlock. At boot, `cmp90hx-compute.service` runs only the existing stock → patched driver handoff; it never calls the Gen2 runner. A stale pending manual register-write request is removed before compute initialization. The upstream installer’s Gen2 service section is omitted before installation; its driver build and patches are unchanged.

`PCIe GEN2` embeds the complete `root-scripts/cmp90hx-gen2-exact-worked.sh` mechanism. The complete exact-worked method runs first on cards below Gen2: unload NVIDIA, reset the target, rescan, stock-to-patched handoff, real register-write cycle and retrain, followed by the original global aggressive XVE and soft passes. Cards already at Gen2 skip the per-card FEAT phase. Driver unloading and global passes still affect all cards.

If exact recovery is exhausted, the separate prior hard-FEAT mechanism selects remaining non-Gen2 cards with closed FEAT, unloads NVIDIA, resets the target, rescans and hands off, then starts up to 13 fresh real FEAT-write attempts. Aggressive XVE and a final soft pass follow. Its function overrides are isolated from the complete exact-worked implementation.

Soft/aggressive limits are 13; the original four FEAT cycles and three final soft rounds are retained. Failure displays a reboot-and-retry suggestion and returns to the menu without closing the tmux panes. No reboot or Gen2 boot service is started automatically.

Install and run:

```bash
wget https://raw.githubusercontent.com/iatethelogs/cmp90hx_pwner/main/rejoin17.sh
chmod +x rejoin17.sh
sudo AUTO_REBOOT_IF_NOUVEAU=1 ./rejoin17.sh
```

If `tmux` is missing, the script installs it before opening the two-pane UI. If `tmux` is already installed, there is no extra startup download.

Or use CLI actions:

```bash
sudo ./rejoin17.sh --compute-unlock
sudo ./rejoin17.sh --gen2
sudo ./rejoin17.sh --verify
```

After each reboot, run `--gen2` again if you want Gen2 active.
