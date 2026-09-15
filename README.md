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

# CMP90HX Pwner (еще не доделан для мультикарточных систем! на 1 карте работает прекрасно)

Полноценное решение для CMP 90HX: снятие вычислительных ограничений и включение PCIe Gen2.


Проект ставит нужный драйвер, применяет патчи, включает PCIe Gen2 и добавляет автозапуск после перезагрузки. После установки карта должна работать без ручных команд: ограничения сняты, Gen2 включается сам при старте системы.

## Возможности

`UNLOCK THIS SHIT` — полная установка с нуля. Скрипт удаляет старые следы предыдущей установки, ставит нужный NVIDIA 610.43.03, собирает патченный вариант, включает Gen2, создаёт автозапуск и сразу проверяет результат.

`VERIFY` — проверка результата. Скрипт проверяет, что карта видна системе, что вычислительные ограничения сняты через родную проверку rejoin/cmpunlocker, и что PCIe работает на Gen2.

`INSTALL CUDA TOOLKIT` — установка CUDA Toolkit. Этот пункт нужен только для установки инструментов CUDA.

`INSTALL 4-BEEP AT START` — установка нашего скрипта, который делает четыре коротких сигнала пищалкой при старте системы.

`INSTALL FAN/GPU HELPERS` — установка наших быстрых команд для управления вентиляторами и режимом карты:

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


### 1. Подготовить чистую систему

Установите Ubuntu на стенд или сервер с CMP 90HX.

Не подключайте монитор к CMP 90HX во время установки. Иначе система может загрузить `nouveau`, и установке потребуется дополнительная перезагрузка. Для настройки используйте SSH!!! С подключенным даже к встроенной графике процессора скрипт работать не будет

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

Если патчи ещё применяются, при первом входе по SSH появится надпись `WAIT`. Ничего не закрывайте и не запускайте тяжёлые задачи на GPU. Нужно дождаться окончания проверки.

На нескольких картах ожидание может быть долгим. В скрипте заложен запас: ожидание до 2000 секунд, системный таймаут службы — 2000 секунд.

Когда всё готово, появится котик и сообщение:

```text
CMP90HX PWNED
ENJOY!
HA HA FULL SPEED
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

# CMP90HX Pwner

A complete solution for the CMP 90HX: removing compute restrictions and enabling PCIe Gen2.

The project installs the required driver, applies the patches, enables PCIe Gen2, and configures automatic startup after reboot. Once installed, the card should work without any manual commands: the restrictions are removed, and Gen2 is enabled automatically when the system starts.

## Features

`UNLOCK THIS SHIT` — full installation from scratch. The script removes old traces of previous installations, installs the required NVIDIA 610.43.03 driver, builds the patched version, enables Gen2, configures automatic startup, and immediately verifies the result.

`VERIFY` — verifies the result. The script checks that the card is visible to the system, confirms that the compute restrictions have been removed using the native rejoin/cmpunlocker verification method, and verifies that PCIe is operating in Gen2 mode.

`INSTALL CUDA TOOLKIT` — installs the CUDA Toolkit. This option is only required if you need the CUDA development tools.

`INSTALL 4-BEEP AT START` — installs our script that plays four short PC speaker beeps during system startup.

`INSTALL FAN/GPU HELPERS` — installs our quick commands for fan and GPU mode control:

```text
fan-100
fan-60
fan-auto
gpu-full
gpu-idle
```

`UNINSTALL` — removes the installed solution. The script disables automatic startup and removes the project files, state files, service scripts, helper commands, and driver files. A reboot is required after removal for the card to return to its original state.

## Screenshots

### Main menu

![Main menu](docs/screenshots/main-menu.png)

### Installation process

![Install process](docs/screenshots/install-process.png)

### Waiting after reboot

![Wait screen](docs/screenshots/wait-screen.png)

### Successful verification

![Success](docs/screenshots/success.png)

### VERIFY check

![Verify](docs/screenshots/verify.png)

### 1. Prepare a clean system

Install Ubuntu on the test bench or server with the CMP 90HX.

Do not connect a monitor to the CMP 90HX during installation. Otherwise, the system may load `nouveau`, and the installation will require an additional reboot. Use SSH for setup!!! The script will not work even if the monitor is connected to the CPU integrated graphics.

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

The script is designed to be launched using the normal `sudo ./rejoin17.sh` method. There is no need to enter `sudo -s`.

### 4. Select the first option

In the menu, select:

```text
1) UNLOCK THIS SHIT
```

The script will perform the installation automatically, overwrite old files, apply the patches, enable Gen2, and configure automatic startup.

If the system asks you to reboot because of `nouveau`, reboot and run the same command again:

```bash
sudo AUTO_REBOOT_IF_NOUVEAU=1 ./rejoin17.sh
```

Select `UNLOCK THIS SHIT` again.

### 5. Reboot after installation

After a successful installation, the script will offer to reboot the system.

If the patches are still being applied, you will see `WAIT` when you first log in over SSH. Do not close anything or start any heavy GPU workloads. Wait until the verification process finishes.

On multi-card systems, waiting may take a long time. The script allows up to 2000 seconds of waiting and uses a 2000-second systemd service timeout.

When everything is ready, a cat and the following message will appear:

```text
CMP90HX PWNED
ENJOY!
HA HA FULL SPEED
```

## What happens after every reboot

During system startup, the `cmp90hx-gen2.service` service is launched. It reapplies the required sequence for the CMP 90HX and verifies the result.

This is necessary because some of the card settings are not guaranteed to persist after a power-off or reboot.

## Used work

This project uses results and code from the following authors:

* `pearlfortune/cmpunlocker` — removal of compute restrictions, rejoin15, V67, FEAT/PLM path `0x823800/0x823804`.
* `jdowning100/cmpunlocker` — rejoin16, Gen2 path, XVE/LTSSM `0x088fe8`.
* `Wh1stle05/cmp90hx` — Linux installer, NVIDIA 610.43.03 build, and patch packaging.

## Warning

This is a low-level experimental project for the CMP 90HX. It modifies the driver, system service files, and the card's behavior during startup. Use it at your own risk.

---
