# Внешний HTTPS для iof-web

iof-web слушает `127.0.0.1:8088`. Nginx принимает HTTPS и проксирует `/admin/` и публичный `/status`.
Администратор входит на `/admin/` с паролем панели. Клиент открывает `/status` без учётной записи и cookie.

## Домен и IP

1. Для доступа по домену направьте его DNS-запись на сервер с nginx и установите сертификат для этого имени.
   Для доступа по IP нужен отдельный сертификат с этим IP в `subjectAltName` или сертификат, покрывающий оба адреса.
2. Добавьте используемые имена и IP через запятую в `/root/iof/web.env`, например `IOF_WEB_HOSTS=panel.example.com,192.0.2.10`.
   После изменения выполните `sudo systemctl restart iof-web`.
3. В каждый HTTPS-блок `server`, где будут доступны панель и статус, добавьте `include /opt/iof/web/nginx-iof.conf;`.
   Пример отдельного сайта для домена с уже выпущенным сертификатом:

   ```nginx
   server {
       listen 443 ssl;
       server_name panel.example.com;
       ssl_certificate /etc/letsencrypt/live/panel.example.com/fullchain.pem;
       ssl_certificate_key /etc/letsencrypt/live/panel.example.com/privkey.pem;

       include /opt/iof/web/nginx-iof.conf;
       location / { return 404; }
   }
   ```

   Для IP используйте `server_name 192.0.2.10` и пути к сертификату для этого адреса. Запросы по IP могут
   поступать без SNI. Если IP обслуживается на том же сокете `IP:443`, что и домен, назначьте сайт с
   IP-сертификатом `default_server` для этого сокета. Для HTTP можно настроить редирект на HTTPS
   с сохранением пути. Фрагмент `nginx-iof.conf` подключайте только в HTTPS-блоки.
4. Выполните `sudo nginx -t && sudo systemctl reload nginx`. После обновления iof повторите эту команду,
   чтобы nginx прочитал новый фрагмент. Если правила `/admin/` ранее скопировали в конфиг вручную,
   замените скопированные правила на `include`, чтобы избежать дублирования.

## Что открывается снаружи

| Путь | Доступ |
|---|---|
| `/admin/` и API панели | Правила входа панели, включая одноразовые билеты для терминала и проверки с ПК |
| `/status` | Публичная страница, GET и HEAD |
| `/status/data.json` | Публичный снимок и история, GET и HEAD |
| `/status/assets/` | GET и HEAD только для `app.css`, `common.js`, `status.js`, `logo-panel.svg` и `favicon.svg` |

Nginx передаёт `Host` и выставляет `X-IOF-HTTPS: 1` для панели и статуса. Приложение сверяет имя или IP
с `IOF_WEB_HOSTS` и проверяет способ подключения. Публичные данные ограничены нейтральными метками
серверов, состояниями, временем и историей. iof-web собирает наблюдения при старте и каждые 5 минут,
сохраняет 30 дней истории и обслуживает публичные запросы из готового снимка.

## Проверка

Запустите команды с доверенным сертификатом для домена, затем повторите с URL на IP:

```sh
curl -I https://panel.example.com/status
curl -fsS https://panel.example.com/status/data.json
curl -i -X POST https://panel.example.com/status/data.json
curl -i https://panel.example.com/admin/api/setup
```

Страница и снимок отвечают `200`, POST — `405`, API панели без сеанса — `401`. На первом запуске
история может быть пустой до первого успешного опроса. При `403` проверьте `IOF_WEB_HOSTS`,
при `404` — подключение фрагмента в нужный HTTPS-блок и перезагрузку nginx, при `502` —
`systemctl status iof-web` и `journalctl -u iof-web -n 30`. После продления сертификата nginx
нужно перечитать его файлы. Проверьте, что это делает настройка вашего клиента ACME.
