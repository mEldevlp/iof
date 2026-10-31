# iof (Island of Freedom)

Управление VPN-серверами (Hysteria2, AmneziaWG) с одного управляющего сервера по SSH
и веб-панель к нему.

## Установка

На управляющем сервере (Ubuntu 24.04):

```
sudo apt update && sudo apt install -y git python3 qrencode
sudo git clone https://github.com/mEldevlp/iof /opt/iof
sudo bash /opt/iof/install.sh
sudo iof status
```

Ставятся `iof`, `iof-nightly` и веб-панель. Данные в `/root/iof` не трогаются.

## Обновление

```
sudo iof update
```

Скачивает новую версию с GitHub и ставит её. Если в `iof.sh` ошибка, рабочий `iof` остаётся прежним.

## Веб-панель

Открывается только через SSH-туннель. На компьютере:

```
ssh -L 8088:127.0.0.1:8088 пользователь@сервер
```

и в браузере http://127.0.0.1:8088/

- **Обзор** — состояние всех серверов, как `iof status`.
- **Hysteria2** — группы ссылок: скопировать для Hiddify, QR-коды.
- **Добавить сервер** — новый сервер по паролю, SSH-ключу или уже добавленному ключу iof,
  сразу с установкой Hysteria2. Работает через `iof node add`, лог виден на странице.

## Ночное обслуживание

`iof-nightly` обновляет пакеты и перезагружает все серверы. Включить (`sudo crontab -e`):

```
0 4 * * * /usr/local/sbin/iof-nightly
```

## Если что-то не так

- Панель не открывается: `systemctl status iof-web`, `journalctl -u iof-web -n 50`.
- Вернуть прошлую версию: `sudo git -C /opt/iof log --oneline`, затем
  `sudo git -C /opt/iof checkout <коммит> && sudo bash /opt/iof/install.sh`.
  Обратно на свежую: `sudo git -C /opt/iof checkout master && sudo iof update`.
- Открыть панель без туннеля (за nginx с HTTPS): в `/root/iof/web.env` задать
  `IOF_WEB_PASSWORD=...` и `IOF_WEB_HOSTS=домен`. Без пароля панель наружу не запустится:
  через неё можно управлять всеми серверами.
