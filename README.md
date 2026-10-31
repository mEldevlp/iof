# iof (Island of Freedom)

Управление группой VPN-серверов (Hysteria2, AmneziaWG 2.0) с одного управляющего сервера
по SSH, плюс веб-панель `iof-web` для просмотра состояния и выдачи ссылок.

- `iof.sh` — сам скрипт, ставится в `/usr/local/bin/iof`
- `iof-nightly` — ночное обновление пакетов и перезагрузка всех узлов, ставится в
  `/usr/local/sbin/iof-nightly`, запускается из cron root: `0 4 * * * /usr/local/sbin/iof-nightly`
  (`sudo crontab -e`; `install.sh` расписание не трогает, только напоминает, если его нет)
- `web/` — веб-панель (python3 без зависимостей), подробности в [web/README.md](web/README.md)
- `install.sh` — установка и обновление обоих из этого репозитория

## Установка на управляющий сервер (Ubuntu 24.04)

```
sudo apt update && sudo apt install -y git python3 qrencode
sudo cp /usr/local/bin/iof /root/iof.backup          # если iof уже стоит
sudo git clone https://github.com/mEldevlp/iof /opt/iof
sudo bash /opt/iof/install.sh
sudo iof status
```

Данные в `/root/iof` (узлы, ссылки, ключи) установка не трогает.
`install.sh --no-web` ставит только `iof`, без панели.

## Обновление

```
sudo iof update
```

Делает `git pull` в `/opt/iof`, показывает новые коммиты и запускает `install.sh`.
Если `iof.sh` не проходит `bash -n`, рабочий `iof` остаётся как был.
Папку клона можно поменять через `IOF_SRC` в `/root/iof/iof.env`.

Откат на прошлую версию: `sudo git -C /opt/iof log --oneline`, затем
`sudo git -C /opt/iof checkout <коммит> && sudo bash /opt/iof/install.sh`.
Вернуться на свежую: `sudo git -C /opt/iof checkout master && sudo iof update`.

## Веб-панель

Слушает только `127.0.0.1:8088`. С компьютера:

```
ssh -L 8088:127.0.0.1:8088 пользователь@сервер
```

и открыть http://127.0.0.1:8088/ в браузере. Состояние: `systemctl status iof-web`,
логи: `journalctl -u iof-web -n 50`.
