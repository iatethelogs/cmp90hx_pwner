# CMP90HX Pwner

Полноценное решение для CMP 90HX: снятие вычислительных ограничений и включение PCIe Gen2.

Репозиторий: https://github.com/iatethelogs/cmp90hx_pwner  
Автор: iatethelogs

Проект ставит нужный драйвер, применяет патчи, включает PCIe Gen2 и добавляет автозапуск после перезагрузки. После установки карта должна работать без ручных команд: ограничения сняты, Gen2 включается сам при старте системы.

## Возможности

`UNLOCK THIS SHIT` — полная установка с нуля. Скрипт удаляет старые следы предыдущей установки, ставит NVIDIA 610.43.03, собирает патченный вариант, включает Gen2, создаёт автозапуск и сразу проверяет результат.

`VERIFY` — проверка результата. Скрипт проверяет, что карта видна системе, что вычислительные ограничения сняты через родную проверку rejoin/cmpunlocker, и что PCIe работает на Gen2.

`INSTALL CUDA TOOLKIT` — установка инструментов CUDA без замены рабочего драйвера. Этот пункт нужен, если в системе нужны `nvcc` и остальные инструменты CUDA.

`INSTALL 4-BEEP AT START` — установка нашего скрипта, который делает четыре коротких сигнала пищалкой при старте системы.

`INSTALL FAN/GPU HELPERS` — установка быстрых команд для управления вентиляторами и режимом GPU:

```text
fan-100
fan-60
fan-auto
gpu-full
gpu-idle
```

`UNINSTALL` — удаление установленного решения. Скрипт отключает автозапуск, удаляет файлы проекта, состояние, служебные скрипты, helper-команды и драйверные файлы. После удаления нужна перезагрузка, чтобы карта вернулась в исходное состояние.

## Скриншоты

### Главное меню

![Main menu](docs/screenshots/main-menu.png)

### Процесс установки

![Install process](docs/screenshots/install-process.png)

### Ожидание после перезагрузки

![Wait screen](docs/screenshots/wait-screen.png)

### Успешная проверка

![Success](docs/screenshots/success.png)

### Проверка VERIFY

![Verify](docs/screenshots/verify.png)

## Как пользоваться `UNLOCK THIS SHIT`

### 1. Подготовить систему

Установите Ubuntu на стенд или сервер с CMP 90HX.

Не подключайте монитор к CMP 90HX во время установки. Иначе система может загрузить `nouveau`, и установке потребуется дополнительная перезагрузка. Для настройки используйте SSH, встроенную графику процессора или другую видеокарту.

Secure Boot должен быть выключен.

### 2. Скачать скрипт

```bash
wget https://raw.githubusercontent.com/iatethelogs/cmp90hx_pwner/main/rejoin17.sh
chmod +x rejoin17.sh
```

### 3. Запустить

```bash
sudo AUTO_REBOOT_IF_NOUVEAU=1 ./rejoin17.sh
```

Запуск рассчитан именно на обычный `sudo ./rejoin17.sh`. Не нужно заходить в `sudo -s`.

### 4. Выбрать первый пункт

В меню выберите:

```text
1) UNLOCK THIS SHIT
```

Скрипт сам выполнит установку, перезапишет старые файлы, применит патчи, включит Gen2 и создаст автозапуск.

Если система попросит перезагрузиться из-за `nouveau`, перезагрузитесь и запустите ту же команду ещё раз:

```bash
sudo AUTO_REBOOT_IF_NOUVEAU=1 ./rejoin17.sh
```

Снова выберите `UNLOCK THIS SHIT`.

### 5. Перезагрузиться после установки

После успешной установки скрипт предложит перезагрузку.

После перезагрузки SSH доступ не блокируется. Если патчи ещё применяются, при первом входе по SSH появится надпись `WAIT`. Ничего не закрывайте и не запускайте тяжёлые задачи на GPU. Нужно дождаться окончания проверки.

На системе с несколькими CMP 90HX применение может занимать несколько минут. Для пяти карт в скрипте заложен запас: ожидание до 1200 секунд, системный таймаут службы — 1500 секунд.

Когда всё готово, появится котик и сообщение:

```text
CMP90HX PWNED
ENJOY!
HA HA FULL SPEED
```

Если вы не зайдёте по SSH сразу после перезагрузки, проверка всё равно пройдёт в фоне. При первом входе после этого котик всё равно покажется один раз.

При следующих входах в эту же загрузку заставка уже не показывается.

## Дополнительные пункты меню

### VERIFY

Запускает полную проверку текущего состояния:

```text
карта видна системе
драйвер NVIDIA загружен
compute unlock проходит родную проверку rejoin/cmpunlocker
PCIe link работает на Gen2
```

Если проверка не прошла, программа не закрывается. Подробности остаются в правом окне с логом.

### INSTALL CUDA TOOLKIT

Ставит только инструменты CUDA. Рабочий драйвер не заменяется.

Используйте этот пункт, если после разблокировки нужны `nvcc`, заголовки CUDA и остальные утилиты CUDA Toolkit.

### INSTALL 4-BEEP AT START

Ставит небольшой systemd-сервис, который при старте системы делает четыре коротких сигнала через PC speaker.

Это удобно для стенда без монитора: по звуку понятно, что система дошла до старта пользовательского окружения.

### INSTALL FAN/GPU HELPERS

Ставит быстрые команды:

`fan-100` — перевести вентиляторы NVIDIA на 100%.

`fan-60` — перевести вентиляторы NVIDIA на 60%.

`fan-auto` — вернуть автоматическое управление вентиляторами.

`gpu-full` — включить постоянный режим, выставить максимальный power limit и снять ручную фиксацию частоты, если она была.

`gpu-idle` — перевести карты в спокойный режим с ограничением мощности и частоты. Значения можно менять через переменные `GPU_IDLE_POWER_LIMIT`, `GPU_IDLE_MIN_CLOCK`, `GPU_IDLE_MAX_CLOCK`.

### UNINSTALL

Удаляет установленное решение и служебные файлы. После удаления нужна перезагрузка.

Важно: если карта уже находится в Gen2, она может оставаться в этом состоянии до следующей перезагрузки. Поэтому возврат в исходное состояние проверяется только после reboot.

## Запуск без меню

Скрипт можно запускать напрямую:

```bash
sudo ./rejoin17.sh --unlock-this-shit
sudo ./rejoin17.sh --verify
sudo ./rejoin17.sh --install-cuda
sudo ./rejoin17.sh --install-beep
sudo ./rejoin17.sh --install-helpers
sudo ./rejoin17.sh --uninstall
```

## Что происходит после каждой перезагрузки

При старте системы запускается служба `cmp90hx-gen2.service`. Она заново применяет нужную последовательность для CMP 90HX и проверяет результат.

Это нужно потому, что часть настроек карты не обязана сохраняться после выключения питания или перезагрузки.

## Использованные работы

В проекте используются результаты и код следующих авторов:

- `pearlfortune/cmpunlocker` — снятие вычислительных ограничений, rejoin15, V67, путь FEAT/PLM `0x823800/0x823804`.
- `jdowning100/cmpunlocker` — rejoin16, путь Gen2, XVE/LTSSM `0x088fe8`.
- `Wh1stle05/cmp90hx` — установщик для Linux, сборка NVIDIA 610.43.03 и упаковка патчей.

## Предупреждение

Это низкоуровневый экспериментальный проект для CMP 90HX. Он меняет драйвер, служебные файлы системы и поведение карты при загрузке. Используйте на свой риск.

---

# CMP90HX Pwner — English

A complete CMP 90HX solution for removing compute restrictions and enabling PCIe Gen2.

Repository: https://github.com/iatethelogs/cmp90hx_pwner  
Author: iatethelogs

The script installs the required driver, applies the patch set, enables PCIe Gen2, and adds automatic re-apply after reboot. After installation, the card should come back with compute restrictions removed and Gen2 enabled without manual commands.

## Features

`UNLOCK THIS SHIT` — full clean installation. It removes previous install traces, installs NVIDIA 610.43.03, builds and installs the patched driver, enables Gen2, creates the boot service, and verifies the result.

`VERIFY` — checks the result. It verifies that the card is present, compute unlock is active through the native rejoin/cmpunlocker check, and the PCIe link is Gen2.

`INSTALL CUDA TOOLKIT` — installs CUDA tools without replacing the working driver.

`INSTALL 4-BEEP AT START` — installs the helper that plays four short PC speaker beeps during system startup.

`INSTALL FAN/GPU HELPERS` — installs quick helper commands:

```text
fan-100
fan-60
fan-auto
gpu-full
gpu-idle
```

`UNINSTALL` — removes the installed solution. It disables the boot service, removes project files, state files, service scripts, helper commands, and driver files. Reboot is required after uninstall.

## Screenshots

### Main menu

![Main menu](docs/screenshots/main-menu.png)

### Installation process

![Install process](docs/screenshots/install-process.png)

### Waiting after reboot

![Wait screen](docs/screenshots/wait-screen.png)

### Success screen

![Success](docs/screenshots/success.png)

### VERIFY result

![Verify](docs/screenshots/verify.png)

## How to use `UNLOCK THIS SHIT`

### 1. Prepare the system

Install Ubuntu on the CMP 90HX test machine or server.

Do not connect a monitor to the CMP 90HX during installation. Use SSH, integrated graphics, or another GPU. This helps avoid `nouveau` being loaded.

Secure Boot must be disabled.

### 2. Download the script

```bash
wget https://raw.githubusercontent.com/iatethelogs/cmp90hx_pwner/main/rejoin17.sh
chmod +x rejoin17.sh
```

### 3. Run it

```bash
sudo AUTO_REBOOT_IF_NOUVEAU=1 ./rejoin17.sh
```

The script is intended to be run with normal `sudo ./rejoin17.sh`. Do not use `sudo -s`.

### 4. Select the first menu item

Choose:

```text
1) UNLOCK THIS SHIT
```

The script will install everything, overwrite old files, apply the patches, enable Gen2, and create the boot service.

If the script asks for a reboot because of `nouveau`, reboot and run the same command again:

```bash
sudo AUTO_REBOOT_IF_NOUVEAU=1 ./rejoin17.sh
```

Then choose `UNLOCK THIS SHIT` again.

### 5. Reboot after installation

After successful installation, the script will ask for reboot.

After reboot, SSH access is not blocked. If the patch process is still running, the first SSH login will show `WAIT`. Do not interrupt it and do not start heavy GPU workloads yet.

On a multi-CMP system, applying the sequence may take several minutes. For five cards, the script uses a 1200-second boot wait and a 1500-second systemd timeout.

When the check passes, you will see the cat and:

```text
CMP90HX PWNED
ENJOY!
HA HA FULL SPEED
```

If you do not log in immediately after reboot, the background check will still finish. The success message will be shown once on your first SSH login after that boot.

## Additional menu items

### VERIFY

Runs a complete check of the current state:

```text
the card is visible to the system
the NVIDIA driver is loaded
compute unlock passes the native rejoin/cmpunlocker check
the PCIe link is running at Gen2
```

If verification fails, the program does not close. Details remain in the right log pane.

### INSTALL CUDA TOOLKIT

Installs CUDA Toolkit only. It does not replace the working driver.

Use this option if you need `nvcc`, CUDA headers, and other CUDA Toolkit utilities after unlocking the card.

### INSTALL 4-BEEP AT START

Installs a small systemd service that plays four short PC speaker beeps during system startup.

This is useful for a headless test bench: the beeps show that the system reached user-space startup.

### INSTALL FAN/GPU HELPERS

Installs quick commands:

`fan-100` — set NVIDIA fans to 100%.

`fan-60` — set NVIDIA fans to 60%.

`fan-auto` — return fans to automatic control.

`gpu-full` — enable persistence mode, set maximum power limit, and reset manual graphics clock locking if it was set.

`gpu-idle` — put the cards into a quiet mode with power and clock limits. Values can be changed with `GPU_IDLE_POWER_LIMIT`, `GPU_IDLE_MIN_CLOCK`, and `GPU_IDLE_MAX_CLOCK`.

### UNINSTALL

Removes the installed solution and service files. Reboot is required after uninstall.

If the card is already running at Gen2, it may stay in that state until the next reboot. Check the original state only after reboot.

## Direct launch without menu

The script can be launched directly:

```bash
sudo ./rejoin17.sh --unlock-this-shit
sudo ./rejoin17.sh --verify
sudo ./rejoin17.sh --install-cuda
sudo ./rejoin17.sh --install-beep
sudo ./rejoin17.sh --install-helpers
sudo ./rejoin17.sh --uninstall
```

## After every reboot

The `cmp90hx-gen2.service` service runs automatically and reapplies the CMP 90HX Gen2 sequence.

This is required because part of the card state may be lost after reboot or power loss.

## Used work

This project uses work from:

- `pearlfortune/cmpunlocker` — compute unlock, rejoin15, V67, FEAT/PLM path `0x823800/0x823804`.
- `jdowning100/cmpunlocker` — rejoin16, Gen2 path, XVE/LTSSM `0x088fe8`.
- `Wh1stle05/cmp90hx` — Linux installer, NVIDIA 610.43.03 build, and patch packaging.

## Warning

This is a low-level experimental project for CMP 90HX. It changes the driver, system service files, and card initialization behavior. Use at your own risk.
