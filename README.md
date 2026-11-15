<p align="center">
  <img src="web/static/favicon.svg" alt="Логотип Island Of Freedom" width="180" height="180">
</p>

<h1 align="center">Island Of Freedom</h1>

<p align="center">
  <a href="https://github.com/mEldevlp/iof/actions/workflows/ci.yml"><img src="https://github.com/mEldevlp/iof/actions/workflows/ci.yml/badge.svg" alt="Проверки CI"></a>
  <img src="https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&amp;logoColor=white" alt="Ubuntu 24.04">
  <img src="https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&amp;logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Python-3-3776AB?logo=python&amp;logoColor=white" alt="Python 3">
  <img src="https://img.shields.io/badge/Hysteria2-2A78D6" alt="Hysteria 2">
  <img src="https://img.shields.io/badge/AmneziaWG-2.0-2A78D6" alt="AmneziaWG 2.0">
</p>

**Island Of Freedom (iof)** - утилита с открытым исходным кодом и веб-панелью для управления VPN-серверами на протоколах
Hysteria 2 и Amnezia 2.0. Позволяет следить за состоянием серверов и управлять VPN через единый интерфейс. 
Так же позволяет администрировать сервера через подключённого Telegram-бота

Данная утилита разрабатывалась полностью для личного пользования, но я решил выложить исходный код. Данная панель не претендует на замену гигантам по типу 3x-ui, она для тех кому надоел нагромождённый интерфейс и хочет пользоваться
по принципу "накатил - работает".

> [!NOTE]
> Выбранные протоколы `Hysteria` и `Amnezia` выбраны потому что `VLESS` в моём регионе вообще на отрез
> отказывается работать. В планах есть всё же добавить поддержку этих протоколов

![Веб-панель: обзор всех серверов](docs/panel-overview.png)

![Веб-панель: страница сервера](docs/panel-node.png)

<details>
<summary>Ещё скриншоты: ссылки Hysteria2, аудит безопасности, терминал, добавление сервера, Telegram-бот</summary>

![Веб-панель: группы ссылок Hysteria2](docs/panel-hy2.png)

![Веб-панель: аудит безопасности серверов](docs/panel-security.png)

![Веб-панель: терминал на сервер в браузере](docs/panel-terminal.png)

![Веб-панель: добавление сервера](docs/panel-add.png)

![Веб-панель: Telegram-бот](docs/panel-bot.png)

</details>

## Установка на Ubuntu 24.04

Выполните на сервере, с которого будете управлять остальными VPS:

```bash
sudo apt update && sudo apt install -y git python3 qrencode
sudo git clone https://github.com/mEldevlp/iof /opt/iof
sudo bash /opt/iof/install.sh
sudo iof status
```

## Обновление

На управляющем сервере:

```bash
sudo iof update
```

## Веб-панель

На своём компьютере откройте SSH-туннель к управляющему серверу:

```bash
ssh -N -L 127.0.0.1:8088:127.0.0.1:8088 пользователь@сервер
```
