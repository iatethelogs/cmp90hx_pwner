```text
  ____   __  __   ____     ___     ___    _   _  __  __
 / ___| |  \/  | |  _ \   / _ \   / _ \  | | | | \ \/ /
| |     | |\/| | | |_) | | (_) | | | | | | |_| |  \  /
| |___  | |  | | |  __/   \__, | | |_| | |  _  |  /  \
 \____| |_|  |_| |_|        /_/   \___/  |_| |_| /_/\_\

      ____   __        __  _   _   _____   ____
     |  _ \  \ \      / / | \ | | | ____| |  _ \
     | |_) |  \ \ /\ / /  |  \| | |  _|   | |_) |
     |  __/    \ V  V /   | |\  | | |___  |  _ <
     |_|        \_/\_/    |_| \_| |_____| |_| \_\

```

Инструмент для CMP 90HX с двумя независимыми действиями: установка compute unlock и ручное включение PCIe Gen2.


![developers](images/main.jpg)

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
![mainmenu](images/menu.jpg)


### COMPUTE UNLOCK

Устанавливает NVIDIA 610.43.03, активирует патченный драйвер и проверяет снятие вычислительных ограничений.



### PCIe GEN2

Последовательно обрабатывает обнаруженные CMP 90HX, пытается включить PCIe Gen2 и после завершения проверяет фактическое состояние PCIe link.

Если включить Gen2 не удалось, программа предложит перезагрузить сервер и повторить запуск.

## Установка

На чистой Ubuntu Secure Boot должен быть выключен. Во время установки не подключайте монитор к серверу: `nouveau` может занять карту до установки нужного драйвера.

Скачайте скрипт.

Сначала один раз выберите:

```text
1) COMPUTE UNLOCK
```

После успешной установки запускайте:

```text
2) PCIe GEN2
```

![PCIEGEN2](images/pcie.jpg)

После каждой следующей перезагрузки повторно запускайте только `PCIe GEN2` - но учитывая вариативность запуска, чтобы избежать долгого ожидания, я рекомендую не перезагружать сервер а просто уводить карты в P8.


## VERIFY

Проверяет отдельно существующий compute unlock и текущее состояние PCIe link. Проверка ничего не применяет и не включает Gen2.

## Дополнительные пункты

`INSTALL CUDA TOOLKIT` — устанавливает CUDA Toolkit без замены выбранного драйвера.

`INSTALL 4-BEEP AT START` — ставит четыре коротких сигнала PC speaker при старте - лично для меня очень удобно, чтобы отслеживать когда можно подключаться по SSH.

`INSTALL FAN/GPU HELPERS` — устанавливает команды:

```text
fan-100 - Выкручивает кулеры всех карт на 100
fan-60 - Выкручивает кулеры всех карт на 60
fan-auto - Возвращает картам автоматический режим охлаждения
gpu-full - перевод карты в P0 путем записи частот
gpu-idle - Перевод карты в P8 путем записи частот
```

`UNINSTALL` — удаляет runtime проекта, драйверные файлы и дополнительные helper-команды.

## Использованные работы

- `pearlfortune/cmpunlocker` — compute unlock, rejoin15, V67 FEAT/PLM `0x823800/0x823804`.
- `jdowning100/cmpunlocker` — rejoin16 / PCIe path, XVE/LTSSM `0x088fe8`.
- `Wh1stle05/cmp90hx` — NVIDIA 610.43.03 Linux installer и packaging патчей.

## Warning

Это низкоуровневый экспериментальный проект для CMP 90HX. Он заменяет NVIDIA kernel modules и меняет состояние PCIe/GPU во время ручного Gen2-прохода. Используйте на свой риск.


---

# English

A tool for CMP 90HX with two independent actions: applying the compute unlock and manually enabling PCIe Gen2.


![developers](images/main.jpg)

## Main menu

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

![mainmenu](images/menu.jpg)

### COMPUTE UNLOCK

Installs NVIDIA 610.43.03, activates the patched driver, and verifies that the compute restrictions have been removed.


### PCIe GEN2

Processes the detected CMP 90HX cards one by one, attempts to enable PCIe Gen2, and verifies the actual PCIe link state when finished.

If Gen2 could not be enabled, the program will offer to reboot the server and try again.

## Installation

On a clean Ubuntu installation, Secure Boot must be disabled. Do not connect a monitor to the server during installation: `nouveau` may claim the card before the required driver is installed.

Download the script.

First, select this once:

```text
1) COMPUTE UNLOCK
```

After a successful installation, run:

```text
2) PCIe GEN2
```

![PCIEGEN2](images/pcie.jpg)

After every subsequent reboot, run only `PCIe GEN2` again. However, because startup behavior is somewhat variable, I recommend avoiding unnecessary server reboots and simply putting the cards into P8 to avoid long waits.

## VERIFY

Checks the existing compute unlock and the current PCIe link state separately. Verification does not apply any changes and does not enable Gen2.

## Additional options

`INSTALL CUDA TOOLKIT` - installs the CUDA Toolkit without replacing the selected driver.

`INSTALL 4-BEEP AT START` - installs four short PC speaker beeps during startup. I personally find this convenient for knowing when the server is ready for an SSH connection.

`INSTALL FAN/GPU HELPERS` - installs the following commands:

```text
fan-100 - Sets the fans on all cards to 100%
fan-60 - Sets the fans on all cards to 60%
fan-auto - Returns all cards to automatic fan control
gpu-full - Puts the card into P0 by writing clock settings
gpu-idle - Puts the card into P8 by writing clock settings
```

`UNINSTALL` - removes the project runtime, driver files, and additional helper commands.

## Referenced work

- `pearlfortune/cmpunlocker` - compute unlock, rejoin15, V67 FEAT/PLM `0x823800/0x823804`.
- `jdowning100/cmpunlocker` - rejoin16 / PCIe path, XVE/LTSSM `0x088fe8`.
- `Wh1stle05/cmp90hx` - NVIDIA 610.43.03 Linux installer and patch packaging.

## Warning

This is a low-level experimental project for the CMP 90HX. It replaces NVIDIA kernel modules and changes PCIe/GPU state during the manual Gen2 procedure. Use it at your own risk.
