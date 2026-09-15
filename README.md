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

Основой единого Gen2-процесса служит приложенный `cmp90hx-gen2-known-good(2).sh`.

1. Каждая карта последовательно проходит мягкий этап known-good. Если он не помог — агрессивный этап и обязательный заключительный мягкий этап для этой же карты.
2. После обхода всех карт состояние проверяется заново. Только оставшиеся без Gen2 карты с закрытой FEAT получают исходное hard-FEAT восстановление: выгрузка NVIDIA → сброс выбранной карты → rescan → handoff → повторные реальные записи FEAT с проверкой и retrain.
3. После восстановления выполняется заключительный мягкий этап для той же карты, включая обработку XVE. Открытый FEAT исключает повторный hard-FEAT сброс.
4. Итоговая проверка охватывает весь первоначальный список карт: исчезновение устройства не считается успехом.

Для мягкого, агрессивного и hard-FEAT этапов установлено по **13 попыток на маску за проход**. Паузы, действия открытия масок и последовательность сильного восстановления сохранены из known-good и его архивной зависимости. `CMP90HX_TOTAL_TIMEOUT` по умолчанию равен 3600 секунд; время проверяется между операциями.

Операции необходимой known-good зависимости встроены в основной процесс. Отдельный `cmp90hx-gen2-minimal.sh` больше не создаётся и не вызывается; его старая установленная копия удаляется при ручном обновлении runtime. Вложенных обходов GPU нет. Предыдущий exact-процесс с четырьмя подготовительными FEAT-циклами удалён.

Адресные записи и сбросы относятся к текущей карте. Выгрузка общего драйвера NVIDIA влияет на весь набор GPU. Лог отмечает PCI-адрес, этап, начало и конец обработки каждой карты.

При неудаче программа предлагает перезагрузить сервер и повторить запуск: состояние карт после загрузки влияет на результат. Автоматической перезагрузки нет; обе панели tmux остаются открытыми, Enter возвращает в меню.

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

`PCIe GEN2` uses the supplied `cmp90hx-gen2-known-good(2).sh` as its primary workflow. Each GPU receives a soft pass, then an aggressive pass and mandatory soft finish if needed. After all GPUs have been visited, remaining non-Gen2 cards with closed FEAT receive the original hard recovery: unload NVIDIA, reset the target, rescan, handoff and fresh real FEAT writes with readback and retrain. A final soft pass, including XVE processing, follows for that same card.

Soft/aggressive/hard-FEAT limits are 13. The required adaptive dependency's operations are embedded without its GPU enumeration; the standalone minimal runner is no longer written or called, and its stale installed copy is removed. The previous four-cycle exact workflow is removed. Shared driver reloads still affect all GPUs; final verification checks the original inventory. Failure suggests rebooting and retrying, preserving both tmux panes. Gen2 remains manual only.

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
