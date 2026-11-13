# iof (Island of Freedom): контекст проекта для Claude

Этот файл Claude Code читает в начале каждого чата в репозитории.

**Правило:** при любом изменении проекта (новая команда, файл, формат данных, эндпоинт панели,
путь на сервере, конвенция) Claude обновляет этот файл в том же изменении. Описанное здесь
должно совпадать с кодом. Если код и файл расходятся, прав код: исправь файл.

## Что это

Bash-утилита `iof` и веб-панель `iof-web` для управления группой VPN-серверов (узлов)
с одного **управляющего сервера** по SSH. Протоколы: Hysteria2 и AmneziaWG 2.0, VLESS в планах.
Целевая ОС: Ubuntu 24.04. Пользователь один, это админ. Все тексты, комментарии, сообщения
и коммиты на русском.

Разработка идёт на Windows (`C:\dev\repos\iof`), а запускается всё только на Linux от root.
Локально можно проверить синтаксис и открыть панель в демо-режиме, см. «Проверка изменений».
Python на машине разработки не установлен (`python` там — заглушка Microsoft Store), Node есть.
Docker Desktop там не запускается: Kaspersky Standard не даёт Windows работать с сокетами AF_UNIX
(ошибка 1920 «The file cannot be accessed by the system» на `%LOCALAPPDATA%\Docker\run\*` и
`docker-secrets-engine\engine.sock`). Вместо него Docker Engine стоит в WSL `Ubuntu-24.04`,
там работает тестовый стенд.

## Файлы репозитория

| Файл | Что это | Куда ставится |
|---|---|---|
| `iof.sh` | вся логика, один bash-скрипт | `/usr/local/bin/iof` (700) |
| `iof-nightly` | ночное обновление пакетов и перезагрузка всех узлов | `/usr/local/sbin/iof-nightly` |
| `install.sh` | установка и обновление из клона; `--no-web` ставит без панели | — |
| `web/iof-web.py` | сервер панели, только stdlib python3 | `/opt/iof-web/iof-web.py` |
| `web/iof_bot.py` | Telegram-бот, только stdlib: класс `Bot`, поток внутри панели, см. «Телеграм-бот» | `/opt/iof-web/iof_bot.py` |
| `web/iof-web.service` | systemd-юнит панели | `/etc/systemd/system/iof-web.service` |
| `web/static/*` | страницы панели: html, js, css. Без подкаталогов: `install.sh` копирует `web/static/*` плоско | `/opt/iof-web/static/` |
| `web/static/xterm.js`, `xterm-fit.js`, `xterm.css` | сторонний код для терминала: `@xterm/xterm` 6.0.0 и `@xterm/addon-fit` 0.11.0 из npm, см. «Терминал» | `/opt/iof-web/static/` |
| `web/probe.ps1` | скрипт проверки с ПК (Windows PowerShell 5.1 и 7), только ASCII; не статика: панель отдаёт его по билету, вписав данные проверки вместо `__IOF_PROBE_CONFIG__` | `/opt/iof-web/probe.ps1` |
| `web/design.md` | цвета, шрифты, размеры, брейкпоинты и классы панели | не ставится |
| `docs/panel-*.png` | скриншоты панели для README в тёмной теме: два на виду, четыре под спойлером; сняты в демо-режиме (см. «Проверка изменений») | не ставится |
| `README.md` | инструкция для пользователя | — |
| `stand/` | тестовый стенд на Docker: `Dockerfile` (Ubuntu 24.04 с systemd и SSH), `compose.yml` (old, node1, node2, new), `stand.sh`, `test.sh` (проверка iof на стенде), `hy2-template.yaml`, `fake-tg.py` (поддельный Bot API для бота) | не ставится; попадает в `/opt/iof` как часть клона |
| `ci/lint.sh` | статические проверки: `bash -n`, shellcheck, разбор и pyflakes для `iof-web.py`, `iof_bot.py` и `stand/fake-tg.py`, `node --check`, правила проекта (NODE_FUNCS, STATIC_FILES, CSP, одинаковое меню во всех html, `probe.ps1`: только ASCII, одна метка, разбор парсером PowerShell, если он есть, LF) | не ставится |
| `.github/workflows/ci.yml` | CI в GitHub Actions, см. «Проверка изменений» | не ставится |
| `.shellcheckrc` | настройки shellcheck: отключены SC2178 и SC2128, ложные срабатывания на local-переменные разных функций | не ставится |

Клон репозитория на сервере лежит в `/opt/iof` (`IOF_SRC`). `iof update` делает `git pull --ff-only`
и запускает `install.sh`. Сначала `install.sh` проверяет синтаксис (`bash -n`, `ast.parse`), и при
ошибке рабочая версия остаётся прежней. Статика панели заменяется целиком.

## Модель: управляющий сервер и узлы

- VPN-клиенты подключаются **к узлам напрямую**: адрес и порт узла записаны в ссылках `hy2://`
  и конфигах AWG. Управляющий сервер в трафике клиентов не участвует.
- Управляющий сервер хранит SSH-ключ к узлам и данные в `/root/iof`, а сам ходит на узлы по SSH.
- Сам управляющий сервер обычно тоже узел: в `nodes.conf` у него ssh = `local`, и команды
  выполняются локально через `bash -c`.
- `iof hy2 install` берёт шаблон конфига Hysteria2 с управляющего сервера
  (`/etc/hysteria/config.yaml` или `$HY2_TEMPLATE`), а CN сертификата — из его сертификата.

## Данные на управляющем сервере (`/root/iof`, 700)

| Путь | Формат |
|---|---|
| `nodes.conf` | `имя \| адрес для клиентов \| ssh (local или user@host[:port]) \| подпись`, `#` = комментарий |
| `relays.conf` | `узел \| через узел \| hy2 порт ретранслятора \| hy2 порт узла \| awg порт ретранслятора \| awg порт узла`, `-` = протокол не ретранслируется |
| `iof.env` | bash, читается через `source`: `TG_TOKEN`, `TG_CHAT`, `PARALLEL`, `IOF_SRC`, `HY2_TEMPLATE`, `HY2_CN` (CN сертификата для `hy2 install`, если сертификата из шаблона здесь нет), `AUDIT_KEEP`, `BLOCKLIST_URL` и `REGISTRY_URL` (списки для блока dpi и `iof block`: текст, IP или CIDR в строке, `#` — комментарий; по умолчанию пусто), `BLOCK_ALLOW` (адреса и сети через пробел, которые блок-лист не блокирует никогда), `HY2_HOP` (диапазон смены портов для `hy2 hop on`, по умолчанию `10000-19999`: ниже портов, которые iof сам выбирает для ретрансляторов и мишеней), `PROBE_TTL` (сколько секунд живут мишени проверки с ПК, 900, допустимо 20–3600) и `PROBE_PORTS` (порт мишеней: пусто — случайный свободный 20000–60000, `a-b` — из диапазона, `N` — этот порт; одинаково для всех узлов) |
| `web.env` | EnvironmentFile панели: `IOF_WEB_PASSWORD`, `IOF_WEB_HOSTS`, `IOF_WEB_TTL`, `IOF_WEB_TERMINAL` (`1` включает терминал), а также `HY2_TEMPLATE`, `IOF_BIN`, `IOF_BASE`, `IOF_SSH_KEY`, `IOF_TG_API` (адрес Bot API, только для стенда и CI; его же берёт `iof bot`) |
| `bot.json` | Telegram-бот (600), пишет только `iof bot`: `enabled`, `username` (по `getMe`), `actions` (действия из бота, по умолчанию `false`), `hy2_links` (`true`), `quiet` (`{"from": "23:00", "to": "08:00"}` или `null`), `admins`: [{`id`, `name`, `username`, `role` (`main` или `regular`), `sound`, `notify` (`null` — по умолчанию, этап 5), `added`}], `invites`: [{`hash` (sha256 от кода), `role`, `created`, `expires`}]. Время — unix |
| `bot.token` | токен бота (600), одной строкой; `bot.lock` — `flock` для `iof bot` |
| `state/<узел>` | последнее состояние для `iof check`: `ok` или текст проблем |
| `hy2/index.tsv` | `логин<TAB>подпись<TAB>создан` |
| `hy2/<логин>.txt` | ссылки группы по строке: узлы, затем ретрансляторы; внутри пароли. У группы со списком портов порт узла со сменой портов — `443,10000-19999` |
| `hy2/<логин>.hop` | пустая метка `iof hy2 add --hop`: в ссылках группы список портов. Без неё ссылки как раньше, с одним портом |
| `awg/index.tsv` | как у hy2 |
| `awg/<логин>/<Подпись>.conf` | конфиг клиента для узла, с **приватным ключом клиента** (больше нигде его нет) |
| `awg/<логин>/<Подпись>.pub` | `публичный_ключ контейнер` |
| `awg/<логин>/*_via_*.conf`, `keys.txt` | пересобираются при каждом `awg keys`/`refresh` |
| `check.last` | итог последнего `iof check` для панели: `time`, `total`, `bad`, `problems` (имена через пробел), `changes` |
| `audit/server.json`, `audit/dpi.json` | последняя проверка блока `iof audit` по узлам: `{"nodes": {имя: {addr, reachable, at, checked, error, checks: [{id, status, value, detail, hint, cmd}]}}}`. Проверка одного узла заменяет только его запись |
| `audit/history.jsonl` | строка JSON на запуск `iof audit run`: `at`, `block` (`server`, `dpi` или `all`), `nodes`, `counts`, `down`, `worse`; хранится `AUDIT_KEEP` последних (по умолчанию 30, задаётся в `iof.env`) |
| `audit/cache/` | для блока dpi: `blocklist.txt` и `registry.txt` (списки по `BLOCKLIST_URL` и `REGISTRY_URL`, рядом `.url` — откуда скачан, `.err` — последняя загрузка не удалась) и `whois-<адрес>.txt` (`состояние\|AS\|организация\|страна`). Всё обновляется не чаще раза в сутки |
| `audit/probe/session.json` | текущая проверка с ПК: `id`, `started`, `expires`, `ttl`, `stopped` (время `probe stop`, 0 — не останавливали), `lists` (`white`, `black`), `nodes`: {имя: {`addr`, `ip`, `local`, `state` (started или почему нет), `port`, `fp` (sha256 сертификата мишени), `hy2_port`, `fw` (opened или open), `error`, `control` (сырые слои контроля), `check` (их итог строкой)}}. Токена в нём нет. Новая `probe start` заменяет его |
| `audit/probe/token` | токен мишеней текущей проверки (600). Его читают только панель (вписывает в скрипт для ПК) и `probe import` (отчёт с токеном не принимается) |
| `audit/probe/<ГГГГММДД-ччммсс>.json` | результат проверки с ПК: `at`, `session`, `confidence` (high, medium, low), `reasons`, `net` (`label` — AS и организация по whois, `ip` — адрес ПК с маской /24, `vpn` no/suspect/yes, `remap`), `internet`, `filtering`, `client`, `lists`, `nodes`: {имя: {`status`, `confidence`, `value`, `detail`, `hint`, `cmd`, `layers`: [{`id`, `title`, `verdict`, `status`, `pc`, `control`, `note`}]}}, `counts`. Хранится `AUDIT_KEEP` последних |
| `probe-white.txt`, `probe-black.txt` | контрольные сайты для ПК, по имени в строке, `#` — комментарий, не больше 10: белый открывается из России всегда (ya.ru, vk.com, gosuslugi.ru), чёрный давно заблокирован РКН (rutracker.org, linkedin.com, instagram.com). Создаются при первой `probe start` |
| `migrate.conf` | только во время переноса: `role` (source на старом, target на новом), `id`, `peer` (адрес SSH другого сервера), `self` (на старом: как новый заходит на него), `started` |
| `migrate-cron` | на новом сервере до `migrate finish`: задания cron старого сервера |
| `hy2-template.yaml` | на сервере, получившем управление переносом: шаблон Hysteria2 (в `iof.env` и `web.env` на него указывает `HY2_TEMPLATE`) |

SSH-ключ iof: `/root/.ssh/iof_ed25519` (+ `.pub`). Создаётся в `iof init` или при первом `node add`.
Логин делается из подписи функцией `name_for`: латиница остаётся как есть, иначе к ней добавляется
sha1-хэш. Повторный запуск с той же подписью даёт тот же логин, поэтому `hy2 add` и `awg add`
идемпотентны.

## Что iof оставляет на узлах

- Hysteria2: `/etc/hysteria/config.yaml` (бэкапы `config.yaml.bak.<ts>`), сервис `hysteria-server`,
  `/etc/sysctl.d/99-hysteria.conf`, лог установки `/var/log/iof-hy2-install.log`.
  Режимы auth: `userpass` (на группу свой пользователь) или `password` (общий пароль).
- Смена портов (`hy2 hop on`): диапазон в `listen` (`listen: :443,10000-19999`), drop-in
  `/etc/systemd/system/hysteria-server.service.d/iof-hop.conf` и скрипт `/usr/local/sbin/iof-hy2-hop-clean`
  (перед стартом службы убирает правила, оставшиеся после её падения; если с nftables служба не поднялась,
  в drop-in ещё `HYSTERIA_FIREWALL_BACKEND=iptables`). Сами правила ставит и снимает Hysteria2: таблицы
  nftables `hysteria_<хэш>` или цепочки iptables `HYSTERIA-PR-<хэш>` в nat. `hop off` убирает всё.
- Обновление Hysteria2 (`hy2 upgrade`): копии бинарника и юнита в `/var/backups/iof-hy2` (три последние),
  лог установщика `/var/log/iof-hy2-upgrade.log`.
- Блок-лист (`iof block`): пакет `ipset` (ставится, если его нет), `/etc/iof/block.list` (время файла —
  когда список скачал управляющий сервер), `/etc/iof/block.allow`, `/usr/local/sbin/iof-block`,
  `iof-block.service`, наборы `iof-block` и `iof-allow`, цепочка `IOF-BLOCK` в таблице raw с переходом
  из PREROUTING. `block off` убирает всё, кроме пакета `ipset`.
- AmneziaWG: docker-контейнер `amnezia-awg2` или `amnezia-awg` (ставит приложение Amnezia VPN),
  конфиг `/opt/amnezia/awg/{awg0|wg0}.conf` внутри контейнера, `clientsTable` ведётся как
  в приложении. Бэкапы перед изменением: `/var/backups/iof-awg` на хосте.
- Ретранслятор: `/etc/iof/relay.rules`, `/usr/local/sbin/iof-relay`, `iof-relay.service`,
  `/etc/sysctl.d/99-iof-relay.conf`. Работает на iptables DNAT+MASQUERADE в цепочках `IOF-*`.
- Проверка с ПК, только на время проверки: юнит `iof-probe-<номер>` (systemd-run, `RuntimeMaxSec` =
  `PROBE_TTL`, `--collect`), его файлы в `/run/iof-probe-<номер>` (сертификат, ключ, токен, `target.py`)
  и, если входящие режутся, два правила ACCEPT в INPUT с комментарием `iof-probe-<номер>`. По сроку или
  `probe stop` `ExecStopPost` снимает правила и удаляет папку, `n_probe_stop` добирает остатки.
- Ночное обслуживание: юнит `iof-nightly` (systemd-run), лог `/var/log/iof-nightly.log`.
  На управляющем сервере лог запуска пишется в `/var/log/iof-nightly-run.log`.
- Перенос управления: новый сервер принимает данные в `/root/.iof-migrate` и удаляет их, когда закончит.
  Чужая папка iof на нём сохраняется в `/root/iof.before-migrate-<ts>`. Старый сервер после
  `migrate finish` хранит прежние данные и ключ iof в `/root/iof.moved-<ts>`.

## Устройство `iof.sh`

- `set -euo pipefail`. Требует root. Порядок в файле: настройки, функции узла `n_*`,
  функции управляющего сервера, точка входа (`case "$cmd"`).
- **`n_*` выполняются на узлах.** `run_on <local|user@host[:port]> <функция> [арг]` отправляет на узел
  через stdin bash-скрипт: `declare -f` всех функций из массива `NODE_FUNCS` плюс вызов.
  Поэтому `n_*` не должны зависеть от остального кода. Новую `n_*` нужно **добавить в `NODE_FUNCS`**.
  Пароли не попадают в аргументы процессов узла. Если пользователь не root, команда идёт через `sudo -n`.
  Для `local` скрипт читается из канала (`bash <(…)`), а не из аргумента `bash -c`: так у аргумента нет
  предела 128 КБ (блок-лист больше) и скрипт не виден в списке процессов.
  Что все `n_*` есть в `NODE_FUNCS`, проверяет `ci/lint.sh`.
- `ssh_cmd`: ключ iof, `BatchMode`, `ConnectTimeout=8`, `StrictHostKeyChecking=accept-new`.
- `read_nodes` заполняет массивы `N_NAME N_ADDR N_SSH N_TITLE`, `read_relays` — массивы `R_*`.
  `select_nodes` кладёт в `SEL` индексы узлов по шаблонам из `-n`.
- **Параллельность:** `pmap <функция> <индексы>` запускает задачи в подшеллах, не больше `$PARALLEL`
  одновременно. Результаты читаются через `pm_out/pm_err/pm_rc/pm_ok`. Переменные из подшелла
  наружу не возвращаются. Ошибки печатает `report_failures` (код 255 без текста = нет SSH).
- Опрос узла: `n_status` печатает `key=value`, `probe_*` складывают ответ в ассоциативный массив `P`,
  `node_issues` формирует текст проблем. На этом построены `status`, `check`, `api status`, `hy2/awg status`.
- Вывод таблиц: `row` разделяет поля TAB, `table` выравнивает их через python, цветовые метки `\001R|G|Y`.
- Новые узлы добавляет `onboard_nodes` из массивов `IM_*`; `push_key_job` кладёт ключ
  (по паролю через sshpass, по ключу или с проверкой `--key-installed`). Пароль или ключ для первого
  входа разбирает `read_auth` (результат в `AUTH_MODE`, `AUTH_PASS`, `AUTH_KEY`), ключ iof создаёт
  `ensure_ssh_key`, sshpass ставит `ensure_sshpass`. Всё это общее для `node add` и `migrate start`.
- `index_set` добавляет, обновляет на месте или удаляет строку в `index.tsv`. Дата создания
  у существующей группы не меняется: `hy2 add` той же подписи и `refresh` её сохраняют.
- **Перенос управляющего сервера** (`iof migrate`). `start` на старом сервере: кладёт ключ на новый,
  проверяет его (`n_migrate_check`: не этот же сервер, есть apt, нет своих узлов), пишет `migrate.conf`
  (role=source), собирает архив (`migrate_bundle`) и через `n_migrate_receive` ставит на новом iof
  из копии `/opt/iof` и раскладывает данные. Затем проверяет `iof api status` на новом сервере.
  `finish` на новом: `n_migrate_demote` на старом (cron, iof-web и `/usr/local/bin/iof` убираются,
  данные уходят в `.moved-`), cron ставится здесь. `cancel` на старом: `n_migrate_abort` на новом,
  блокировка снимается. Номер `id` в `migrate.conf` обоих серверов защищает от снятия не того сервера.
  Пока здесь role=source, `migrate_guard` в точке входа запрещает команды, которые что-то меняют
  (список в `case "$cmd:${1:-}"`, в том числе `hy2 hop`, `hy2 upgrade`, `block on|update|off`,
  `bot token|on|off|set|invite|redeem|admin`; для
  трёхсловных — в `case "$cmd:${1:-}:${2:-}"`, там `audit probe start|stop|import`); `exec`, `check`,
  `status`, `update`, `audit run`, `audit probe list` и просмотр разрешены.
  При добавлении новой меняющей команды её нужно внести в этот список.

- **Telegram-бот** (`iof bot`, план и решения в `bot-plan.md`). Сам бот — поток панели (`web/iof_bot.py`),
  он только читает `bot.json` и `bot.token`, а меняет их `iof bot` (из консоли, из панели и из бота).
  JSON ведёт встроенный python `BOT_PY` (режимы `getme`, `edit <операция>`, `show`), пишет новым файлом
  через `os.replace` с правами 600. Меняющие подкоманды берут `flock` на `bot.lock` (`bot_lock`, fd 9).
  - `bot token`: токен со stdin (в терминале `read -s`), проверка формата и `getMe` (python, токен через
    stdin), затем `bot.token` и `username`. Пустой ввод удаляет токен и выключает бота. Адрес Bot API —
    `bot_api`: `IOF_TG_API` из окружения (так передаёт панель) или из `web.env`, иначе Telegram. Прокси нет.
  - `bot invite main|regular`: код — sha256 от 32 случайных байт (64 знака hex), печатается отдельной строкой
    (по ней панель найдёт код) и ссылкой `t.me/<бот>?start=<код>`; в `bot.json` sha256 кода, роль, срок 24 ч.
    Не больше 20 неиспользованных. `invite del <начало хэша>` (от 6 знаков) отзывает.
  - `bot redeem` вызывает поток бота: со stdin код, ID, имя, username. Печатает `result=added|already|bad`
    и `role`. Истёкшие приглашения выбрасываются при любой записи, поэтому истёкший код — тоже `bad`.
    Уже админ — `already`, приглашение не тратится.
  - `bot set actions|links on|off`, `set quiet ЧЧ:ММ-ЧЧ:ММ|off`, `admin set <ID> role|sound`, `admin del`, `show`
    (без кодов и токена; показывает, работает ли панель, `IOF_TG_API` и перенос).

- **Аудит безопасности** (`iof audit`, этапы 1–4 плана «Безопасности»; план выполнен, его файл удалён). Блоков два:
  `server` («Аудит сервера») и `dpi` («Защита от РКН (ТСПУ)»). `iof audit run [server|dpi|all]`,
  по умолчанию `all`; `audit cron` проверяет оба. Общее устройство:
  - Узел только собирает факты строками `ключ=значение`: `n_audit_server` (sshd -T, файрвол, fail2ban,
    обновления, sudo, pwquality, SUID) и `n_audit_dpi`; `n_audit_listen` разбирает `ss`,
    `n_audit_expect` печатает порты контейнеров Amnezia и правила ретранслятора. Python на узле не нужен.
  - Оценку (`good`, `warn`, `crit`, `none`), значение, «как исправить» и команды ставят
    `audit_eval_server` и `audit_eval_dpi` на управляющем сервере, тексты «почему это важно» —
    в `audit_catalog` (строки `B` блок, `G` группа, `K` проверка). Что на узле ожидаемо, а что лишнее,
    для обоих блоков решает `audit_ports`.
  - `audit_job` для pmap печатает `@<блок>` и факты блока, `audit_results` отдаёт их в `AUDIT_PY`
    (режимы `save`, `api`, `show`; строка `R` начинает блок). JSON ведёт встроенный python, поэтому
    `iof audit` требует python3. Запуск `all` даёт одну строку истории.
  - `audit run` принимает `-n`, узлы не меняет и во время переноса разрешён; `audit cron` шлёт
    в Telegram только ухудшения относительно прошлой проверки (потеря связи ухудшением не считается).
    Команды в советах не должны отрезать iof: root остаётся с `prohibit-password`, ufw сначала
    открывает порты узла. `install.sh` подсказывает строку cron, сам расписание не трогает.
- **Блок dpi** показывает, чем узел заметен для фильтров и зондов. Правила:
  - Тексты не обещают защиту: «снижает заметность», «проверка показала». Где правильного ответа нет
    (Salamander или masquerade, порт), ставится `warn` или `none` с объяснением компромисса, не `crit`.
    `crit` только у трёх проверок: параметры AWG как у WireGuard, адрес в реестре, панель на внешнем адресе.
  - Секреты в панель, JSON, лог задачи и вывод iof не попадают. Пароль Salamander узел не отдаёт:
    он входит только в хэш блока `obfs`. Пакеты I1–I5 AWG входят только в `awg_hash`. Значения Jc,
    Jmin, Jmax, S1–S4, H1–H4 приходят на управляющий сервер (они и так лежат в конфигах клиентов),
    но в текст оценки идут только названия полей. Хэши короткие (12 знаков sha256) с солью запуска
    `AUDIT_SALT`: соль нигде не сохраняется, сравнение возможно только внутри одной проверки.
    Поэтому «одинаковые параметры AWG на узлах» при проверке одного узла получают `none`.
  - Расхождение с шаблоном: `n_audit_hy2_blocks` хэширует блоки верхнего уровня конфига без
    комментариев и пользователей `auth.userpass`; управляющий сервер считает той же функцией хэши
    шаблона (`HY2_TEMPLATE` из `iof.env` или `/etc/hysteria/config.yaml`).
  - Параметры AWG разбирает `n_audit_awg_params` (читает и закомментированные `# I1 = …`), границы
    проверяет `audit_awg_check`: Jc 1–128, 0 ≤ Jmin < Jmax < 1280, S1 ≤ 1132, S2 ≤ 1188, S3 ≤ 1216,
    S4 ≤ 32, S1 + 56 ≠ S2, H1–H4 — число или диапазон `начало-конец` в 5–2147483647 без пересечений.
    Числа из документации GL.iNet, запрет пересечений из документации Amnezia. Порядок H1 < H2 < H3 < H4
    не требуется. Обычный WireGuard: полей нет или Jc = 0, S1–S4 = 0, H1–H4 = 1, 2, 3, 4.
  - Снаружи на узел смотрит управляющий сервер, `audit_outside` в том же задании pmap, строки `x_*`:
    порты 80 и 443/tcp, сертификат (openssl), ping, PTR (`getent hosts`), зонд согласования версий
    QUIC, приветствия лишних портов, whois, реестр. Сетевые помощники — встроенный python
    `AUDIT_NET_PY` (режимы `quic`, `banner`, `whois`, `inlist`). Каждая внешняя команда под `timeout`.
    Для узла `local` это взгляд не снаружи: в подробностях об этом сказано.
  - Зонд QUIC: пакет с версией `0x1a2a3a4a`, 1200 байт. Сервер QUIC отвечает Version Negotiation
    (`vn`), под Salamander не отвечает (`silent`). `vn` при Salamander в конфиге значит, что служба
    не перезапущена. GET по HTTP/3 делается, только если curl собран с HTTP3 (в Ubuntu 24.04 нет).
  - whois: свой запрос на порт 43, `whois.iana.org` → региональный реестр (для ARIN `n + адрес`,
    ещё один переход по `ReferralServer`). Нет номера AS — значение «не определён», `none`.
    Частный адрес не запрашивается.
  - Списки `BLOCKLIST_URL` и `REGISTRY_URL` качает `audit_fetch` в `audit/cache`. Реестр — только IPv4.
    Блок-лист: набор ipset `iof-block`, цепочка `IOF-BLOCK` в таблице raw с переходом из PREROUTING,
    служба `iof-block`, время списка — `/etc/iof/block.list` на узле (`block_*`). Нет iptables — `none`.
    Port hopping (`n_hy2_hop_rules`): диапазоны, перенаправленные на порт Hysteria2, из nftables и iptables,
    в том числе через цепочку `HYSTERIA-PR-*`; цепочки `IOF-*` ретранслятора не учитываются. `good` —
    диапазон в `listen` и правила на него есть, диапазон без правил — `warn`, правила без `listen` — «вне iof».
  - Действия: у проверок `hy2_hop` и `blocklist` строка `C` несёт седьмое поле — действия панели на этом
    узле через пробел (`hop_on`, `hop_off`, `hy2_upgrade`, `block_on`, `block_update`, `block_off`), в JSON
    это `act`. Ставит их `audit_eval_dpi` по фактам узла.
- **Действия по результатам проверки** (этап 4): iof сам меняет узлы. Всё под `migrate_guard`.
  - `hy2 hop on|off <узлы|all> [--ports a-b]`: `n_hy2_hop` дописывает диапазон в `listen` после основного
    порта (`listen: :443,10000-19999`). Hysteria2 (от `HY2_HOP_MIN` = 2.12.3: раньше её правила заворачивали
    и исходящий UDP узла) слушает основной порт, остальные перенаправляет сама: nftables, если есть `nft`,
    иначе iptables, и снимает правила при остановке. Основной порт не меняется, поэтому выданные ссылки,
    ретрансляторы (DNAT на основной порт) и шаблон работают как раньше. Файрвол узла открывать не нужно:
    REDIRECT в nat PREROUTING раньше filter INPUT. Проверки перед включением: версия, порты диапазона не
    заняты (слушатели UDP, `relay.rules`, опубликованные порты Docker, nat-перенаправления, порты
    ретрансляторов из `relays.conf`), `PROBE_PORTS` не внутри диапазона. После перезапуска `n_hy2_hop_ready`
    ждёт слушатель и правила; с nftables не вышло — второй заход с `HYSTERIA_FIREWALL_BACKEND=iptables` в
    drop-in; не вышло и так — конфиг и drop-in возвращаются (`n_hy2_last_error` даёт причину из журнала).
    Затем пересобираются группы с меткой `.hop`. `n_free_ports` (новые ретрансляторы) и мишени обходят
    диапазон, `hy2 install` диапазон из шаблона не переносит, `n_audit_hy2_blocks` сравнивает у `listen`
    только основной порт.
  - Ссылки: список портов `host:443,10000-19999` (формат URI Hysteria2) только у групп `hy2 add --hop`.
    Его понимают официальный клиент и Hiddify с 5.5.5 (ray2sing разбирает его с 3.10.2026), а v2rayN
    (System.Uri) и Hiddify старше такую ссылку не импортируют, поэтому по умолчанию ссылки прежние.
    Параметр `mport` (v2rayN, 3x-ui) iof не пишет: Hiddify его не читает. Ссылка через ретранслятор
    всегда с одним портом.
  - `hy2 upgrade <узлы|all>`: `n_hy2_upgrade` запускает официальный установщик (конфиг он не трогает,
    юнит перезаписывает и сам перезапускает службу); бинарник и юнит до этого копируются, служба
    не поднялась — возвращаются.
  - `block on|off <узлы|all>`, `block update [узлы]` (для cron, только там, где список включён):
    `block_prepare` чистит список встроенным python (`AUDIT_NET_PY blocklist`): только IPv4, без частных
    и служебных сетей (Docker, внутренние сети), без записей шире `/BLOCK_MIN_PREFIX` (16). Список уходит
    на узел gzip+base64, вместе с адресами, которые не блокируются (`block_allow`: адреса узлов и их SSH,
    `hostname -I` этого сервера, `BLOCK_ALLOW`); узел добавляет свои адреса, loopback и собеседников
    текущих сессий SSH. `n_block_apply` подменяет наборы через `ipset swap`. Не скачался — на узлы идёт
    прошлая копия. Нет iptables — отказ (только nftables iof не поддерживает).
- **Проверка с ПК** (`iof audit probe`, этап 3): доходит ли трафик до узлов через провайдера ПК.
  - `probe start [--ttl с]` (с `-n`): токен (16 байт hex) пишется в `audit/probe/token`, на узлах
    `n_probe_start <номер> <ttl> <PROBE_PORTS> <токен>` поднимает мишень, затем в том же задании pmap
    (`probe_start_job`) управляющий сервер проходит до неё все слои: `AUDIT_NET_PY trace`, токен через stdin.
    `AUDIT_PY probe-session` пишет `session.json`; ни одна мишень не поднялась — сессии нет, код 3.
    Новая проверка не начинается, пока мишени прошлой живы и её не остановили (`probe_free`).
  - Мишень: python3 из heredoc в `n_probe_start` (`/run/iof-probe-<номер>/target.py`), TCP и UDP на одном
    порту. TLS с сертификатом от `openssl req -x509` (EC, случайный CN), первой строкой ждёт
    `IOF-PROBE <токен>`, отвечает `OK <IP источника>` и 256 КБ; иначе закрывает соединение молча.
    UDP отвечает только на пакет с `IOFP<токен>`, возвращая его той же длины с токеном, заменённым нулями.
    Порт выбирается свободным по `ss` и мимо перенаправлений: правил ретранслятора, nat (port hopping),
    диапазона в `listen` Hysteria2. Входящие режутся (ufw deny, политика DROP или запрет последним правилом
    INPUT) — `ExecStartPre` вставляет ACCEPT с комментарием, `ExecStopPost` снимает. Своя таблица nftables
    с политикой drop — `probe=nft`, мишень не поднимается. Нет python3 или openssl — `nopython`, `noopenssl`.
    В командах `-p ExecStartPre=…` нет `$` и `%`: systemd-run раскрыл бы их сам.
  - Слои (одинаковые у контроля и у `probe.ps1`): `icmp` (ping ×3), `conn` ×3 (TCP, TLS без SNI со сверкой
    отпечатка, 256 КБ), `udp` и `quic` (5 пакетов: 68 байт, или 1200 байт за заголовком QUIC v1 Initial,
    метка со смещения 26), `hy2` (зонд QUIC с версией `0x1a2a3a4a` на порт Hysteria2, как в блоке dpi),
    у ПК ещё `tunnel` (hysteria.exe), контрольные сайты `lists` и `client` (адаптеры VPN, прокси).
  - `probe import` (отчёт со stdin, до 300000 байт): `AUDIT_PY probe-src` находит IP источника,
    `AUDIT_NET_PY whois` без кэша, `AUDIT_PY probe-import` сверяет `session` и что в отчёте нет токена
    и считает вердикт. Слой: `ok`, `blocked`, `stall` (данные встали, у контроля пришли), `partial`,
    `mitm` (отпечаток не совпал), `fail` (туннель), `down` (контроль тоже не прошёл), `unknown`, `skipped`.
    Уверенность отчёта: `low` — IP источника равен адресу узла или частный без `remap`, не открылся ни один
    белый сайт; `medium` — адаптер VPN, страна по whois не RU, открываются все чёрные сайты, часть белых;
    иначе `high`. Меньше трёх попыток у узла — не выше `medium`. Статус (`layer_status`): при `low` всё
    `none`; `crit` только `blocked` и `stall` при `high`; ping — справка, не хуже `none`.
  - `probe stop` останавливает мишени сессии (`n_probe_stop <номер>`) и ставит `stopped`, сессия остаётся
    для `import`. Без сессии убирает все `iof-probe-*` на выбранных узлах. `probe list` — последний
    результат по слоям и прошлые. Узел `local` в контроле — взгляд не снаружи, об этом пишется в `detail`.
  - `remap` в отчёте ставит `probe.ps1`, когда задан `IOF_PROBE_MAP` (стенд): частный IP источника тогда
    не считается VPN, а в причинах сказано, что путь не через провайдера.
- Не проверено: разбор конфига AWG на живом контейнере (на стенде AmneziaWG нет, проверен на подставном
  конфиге в формате `awg0.conf` контейнера `amnezia-awg2`), GET по HTTP/3, whois для адреса узла целиком
  (помощник проверен на публичных адресах отдельно), CrowdSec. Проверка с ПК из России с настоящим
  провайдером (на стенде ПК ходит к контейнерам через WSL), мишень за `ufw` (на стенде проверена политика
  DROP iptables), узел с одной таблицей nftables. Этап 4: `hy2 upgrade` со старой версии (на стенде
  Hysteria2 уже последняя), смена портов с правилами nftables целиком (в ядре WSL нет fib для IPv6, там
  проверен переход на iptables), ссылки со списком портов в настоящем Hiddify и v2rayN (формат взят из
  их исходников), блок-лист с Docker и `ufw` на узле.

Команды: `status`, `check` (для cron, Telegram, пишет `check.last`), `exec`, `refresh`, `init`,
`api status|service|updates|audit` (audit — JSON), `audit run [server|dpi|all]|show|cron`,
`audit probe start [--ttl с]|stop|import|list`, `update`, `version` (версию подставляет `install.sh` в `IOF_VERSION`),
`node add|import|del|list`, `hy2 install|add [--hop|--no-hop]|del|list|show|refresh|status|restart|hop on|off|upgrade`,
`block on|update|off`,
`bot show|token|on|off|set|invite|redeem|admin`,
`awg add|keys|del|show|export|list|clients|refresh|status`, `relay add|del|list|apply`,
`migrate start|finish|cancel|status`, `vless` (заглушка, WIP). Полный список в `usage()`.

## Веб-панель `iof-web`

- `ThreadingHTTPServer` на `127.0.0.1:8088`, работает от root. Открывается через SSH-туннель.
  Слушать не на loopback без `IOF_WEB_PASSWORD` откажется (HTTP Basic, имя пользователя любое).
- **Читает** файлы `/root/iof` напрямую. **Меняет** что-либо только через команды `iof`
  в классе `Jobs`: одна задача за раз, лог в памяти (10 задач, 600 строк, 900 с на шаг).
  Исключения: терминал на узел (`Terminals`, см. ниже), он выключен без `IOF_WEB_TERMINAL=1`, и
  Telegram-бот: он вызывает `iof bot redeem` сам, а не задачей `Jobs` (команда быстрая, узлы не трогает,
  и код приглашения не должен ждать, пока идёт `hy2 install`); так же и страница «Телеграм бот»
  (`POST /api/bot` вызывает `iof bot` сразу, см. ниже).
  У задачи есть вид `kind` (`node` — добавление, `migrate`, `hy2`, `service`, `audit`, `probe`, `node:<имя>` —
  действия с узлом, `bot` — действия Telegram-бота): по нему страница находит свои задачи. Ссылки `hy2://`
  в логе задачи без пароля (`HY2_SECRET`).
  По завершении задачи кэш статуса сбрасывается. Если в выводе есть строка, начинающаяся
  с `Ошибки (`, задача получает состояние `warn`: так поступают `hy2 install`, `migrate start`
  и `migrate cancel`. То же для строк из `WARN_LINES` (`hy2 add/del/refresh` не на всех узлах).
  Четвёртое поле шага — коды выхода, которые значат `warn`, а не `error`, если в выводе нет строки
  «Ошибка…»: так `check_steps` (`iof check` выходит с 1, когда на узлах проблемы).
- Статус узлов: `StatusCache` запускает `iof api status`, держит ответ `IOF_WEB_TTL` секунд
  (по умолчанию 20). `force` обновляет не чаще раза в 5 с, таймаут 180 с. `fresh(force)` не ждёт и говорит,
  ответит ли `get` сразу (так бот решает, писать ли «опрашиваю узлы…»).
- Данные страниц узла, «Сервиса» и «Безопасности» собирают функции `node_view`, `service_view`, `security_view`
  (обработчики только отдают их JSON). Их же через объект `BotViews` берёт Telegram-бот: модуль с дефисом
  в имени не импортируется. В `BotViews.hy2()` у групп нет самих ссылок (в них пароль), только узлы и `hop`;
  ссылки с паролями отдаёт только `BotViews.hy2_links(логин)`, PNG с QR — `qr_png` (`qrencode -t PNG`, текст
  через stdin). Шаги кнопок «Hysteria2», узла и «Безопасности» собирает `action_steps(srv, kind, body)`
  (`hy2_steps`, `node_steps`, `audit_steps`, `check_steps`): им пользуются `job_for` панели и бот через
  `BotActions.plan` (у узла только `restart_hy2`, без действий из `AUDIT_ACTIONS`).
- API: `GET /api/dashboard`, `/api/hy2`, `/api/hy2/qr?g=<логин>&i=<n|all>`, `/api/nodes/add-info`,
  `/api/migrate`, `/api/node?n=<имя>`, `/api/service[?fetch=1]` (через `iof api service|updates` и логи
  `/var/log/iof-nightly*.log`), `/api/jobs`, `/api/term/ws?t=<билет>` (WebSocket терминала);
  `POST /api/nodes` (добавление сервера, при необходимости
  `iof hy2 install`), `POST /api/migrate` (`action`: start, finish или cancel), `POST /api/hy2`
  (`add|del|refresh`; у `add` необязательный `hop: true|false` → `hy2 add --hop|--no-hop`, кнопка
  «Список портов» группы с диалогом `#hop-dialog`; в группах `hop`, у ссылок `hop` и `port` строкой),
  `POST /api/node` (`restart_hy2|install_hy2|delete`, удаление = `node del` + `refresh`),
  `POST /api/term` (`{name, cols, rows}` → одноразовый билет терминала),
  `GET /api/security` (вывод `iof api audit` плюс `error`, `busy`, `migrate`, `probe_state`; узлы не опрашивает;
  в `settings` ещё `hop` — диапазон `HY2_HOP`, `block_cron`, `blocklist`) и
  `POST /api/security` (`{block: "server" | "dpi", node}` → задача вида `audit`:
  `iof [-n узел] audit run <блок>`; блоки перечислены в `AUDIT_BLOCKS`; `{action, node}` → действие из
  `AUDIT_ACTIONS` только на одном узле по имени и при переносе отказ: `iof hy2 hop on|off`, `hy2 upgrade`,
  `block on|update|off` с этим узлом, затем `iof -n <узел> audit run dpi`. Страница «Безопасность»,
  `security.html` + `security.js`: у каждого блока из `BLOCKS` свои `#<блок>-node`, `-run`, `-stamp`,
  `-health`, `-checks`, отрисовка общая (`renderBlock`); в раскрытой проверке из `ACT_CHECKS` кнопка
  открывает диалог `#act-dialog`: список узлов, состояние проверки на выбранном и его действия из `act`
  с описанием `ACTS`; демо-данные обоих блоков в `security.js`, действия в демо меняют `demoAct`),
  проверка с ПК (класс `Probes`, задачи вида `probe`): `POST /api/probe` (`{action: "start", nodes, origin}` →
  задача `iof [-n узлы] audit probe start` и билет `secrets.token_urlsafe`; `origin` — адрес панели в браузере,
  сверяется с `IOF_WEB_HOSTS`; `{action: "cancel"}` → `audit probe stop`), `GET /api/probe` (сессия из
  `session.json` без токена и отпечатков, билет — пока скрипт не забран), `GET /api/probe/script?t=`
  (без пароля панели, по билету один раз: `probe.ps1` с JSON проверки в base64 вместо метки, `no-store`,
  `Content-Disposition`; пока сессии этого запуска нет — 409) и `POST /api/probe/result?t=` (без пароля, с
  обычной защитой POST, но без требования `Origin`; до 256 КБ, один раз, до конца мишеней плюс 300 с).
  Отчёт становится задачей «Проверка с ПК: результат»: сначала `audit probe stop`, потом `audit probe import`
  со stdin, так мишени не переживут проверку при отказе import. Если `Jobs` занят, отчёт ждёт
  и запускается из `on_done` (`Probes.kick`). Билет живёт только в памяти: после перезапуска панели
  страница предлагает остановить проверку и начать заново. Билет в журнал не пишется (`TICKET_IN_URL`).
  Команда для ПК на странице (`probeCommand`): `iwr … -OutFile iof-probe.ps1; powershell … -File .\iof-probe.ps1`.
  Не `iex (iwr …)`: Kaspersky через AMSI блокирует такой запуск как загрузчик вредоносного кода
  («ScriptContainedMaliciousContent»), а тот же скрипт из файла пропускает (проверено на этой машине).
  `POST /api/service` (`update`: `iof update` через `systemd-run --pipe --wait`, потому что install.sh
  перезапускает панель; вывод через `tee -p` ещё и в `/var/log/iof-update.log`, без этого `iof update`
  падал с кодом 1 на записи в оборванную трубу. Страница «Сервис» ждёт перезапуска, сравнивает
  версию и показывает вывод из этого файла).
  `GET /api/bot` (`config` — `bot.json` через `read_bot`: поля по умолчанию как у `iof bot`, у приглашений
  только начало хэша (`BOT_HASH`, 12 знаков, как в `iof bot show`), истёкшие не показываются; `token` —
  `true|false`, сам токен панель не отдаёт; `thread` — `srv.bot.state()` или `null`, тогда причина в
  `thread_error` (`srv.bot_error`: модуль не загрузился или `Bot` упал); `config_error`, `tz` — смещение
  времени сервера для тихих часов, `migrate`) и `POST /api/bot` (`action`: `token` {`token`} или {`delete: true`},
  `enable` {`on`}, `set` {`key`: actions|links, `on`} или {`key`: quiet, `value`: `ЧЧ:ММ-ЧЧ:ММ`|off}, `invite`
  {`role`}, `invite_del` {`hash`}, `admin_set` {`id`, `role` или `sound`}, `admin_del` {`id`}): `bot_args` проверяет
  поля, `iof_bot_cmd` запускает `iof bot` сразу, токен — только stdin. Ответ — `message` (первая строка вывода
  iof) и свежий `bot`, на `invite` ещё `invite` {`code`, `link`, `role`, `hash`, `expires`}: код страница видит
  один раз. При ошибке — 400 с `error` и `bot`. В журнал пишется только команда (`бот: из панели iof bot …`).
  При переносе (`role=source`) отказ ещё до iof (`not_migrating`).
  Состояние переноса (`read_migrate`, поле `migrate`) есть в ответах dashboard, hy2, add-info, migrate
  и bot; `renderMigrate` в `common.js` показывает по нему плашку `#migrate-banner`.
- Защита: проверка `Host` против DNS rebinding (`IOF_WEB_HOSTS`). POST принимается только
  с заголовком `X-IOF-Request: 1`, `Content-Type: application/json` и своим `Origin` (защита от CSRF).
  CSP `default-src 'self'`: **никаких inline-скриптов и `style=`** (ширина задаётся через CSSOM),
  внешних CDN тоже нет.
- Статика отдаётся **только из словаря `STATIC_FILES`**: новую страницу надо добавить туда
  (`ci/lint.sh` сверяет словарь с `web/static` и ищет в статике то, что запрещает CSP).
- **Терминал** на странице узла (кнопка «Терминал», `term.js`, на сервере класс `Terminals`):
  - Страница берёт билет `POST /api/term` (обычная защита от CSRF; билет на 30 с, одноразовый, привязан
    к узлу и размеру окна) и открывает WebSocket `/api/term/ws?t=`. Пароль панели там не проверяется,
    вместо него билет. Проверяются `Host` и `Origin`. Билет в журнал панели не пишется (`TICKET_IN_URL`).
  - WebSocket (RFC 6455) написан вручную, класс `WebSocket`: сообщения целиком, ping, close, до 1 МБ.
    От браузера: двоичные сообщения — ввод, текстовые — JSON `resize` или `ping` (раз в 25 с). К браузеру:
    двоичные — вывод, текстовое `{"type":"exit","code"}` — процесс завершился. 90 с тишины = связь пропала.
  - Процесс: `os.openpty` + `subprocess.Popen` (не `pty.fork`: панель многопоточная), команда
    `setsid -c` (своя сессия, управляющий терминал) + `ssh -t` с ключом iof и опциями как у `ssh_cmd`
    или `<оболочка root> -l` для `local`. Под systemd ещё `systemd-run --scope` (юнит `iof-term-<узел>-<hex>`):
    перезапуск панели не убивает запущенное через nohup или tmux. Окружение собирается с нуля
    (`Terminals.environment`): в окружении панели лежит `web.env` с паролем.
  - Закрытие окна или вкладки = SIGHUP группе процессов, через 3 с SIGKILL. Не больше 4 терминалов
    вместе с невыкупленными билетами. В журнал (`journalctl -u iof-web`) — только открытие и закрытие.
  - xterm.js сам создаёт элементы `<style>`, а CSP их блокирует (терминал выходит чёрным). `term.js`
    (`adoptScriptStyles`) подменяет `document.createElement("style")` на `<template>` и переносит текст в
    `document.adoptedStyleSheets`: на constructable stylesheets CSP не распространяется. xterm.js грузится
    лениво, при первом открытии; `xterm.css` подключён в `node.html`.
  - Сторонние файлы обновляются только целиком: `npm pack @xterm/xterm@<версия> @xterm/addon-fit@<версия>`,
    `lib/xterm.js` → `xterm.js`, `lib/addon-fit.js` → `xterm-fit.js`, `css/xterm.css` → `xterm.css`;
    в начало — комментарий с пакетом, версией и текстом лицензии MIT, строка `sourceMappingURL` убирается.
    `ci/lint.sh` не проверяет их по правилам CSP (массив `VENDOR`), но требует первую строку с пакетом и версией.
- **Телеграм-бот** (`iof_bot.py`, класс `Bot`, поток `iof-bot`; план — `bot-plan.md`, сделаны этапы 1–4):
  - `iof-web.py` импортирует модуль в `try`: если он не загрузился или `Bot` упал при создании, панель
    работает без бота, пишет причину в журнал и в `srv.bot_error` (её показывает страница). В `Bot` передаются
    `Jobs`, `StatusCache` (`cache`), `BotViews` (`views`), `BotActions` (`actions`), путь к `iof` и `IOF_TG_API`.
    Всё, что бот пишет в журнал, идёт через маску пароля ссылок (`LINK_SECRET`). `srv.bot.state()` —
    `state` (starting, off, no_token, migrate, running, error, conflict), `error`, `since`, `username`, `api`
    (если не Telegram).
  - Цикл: `load` перечитывает `bot.json` и `bot.token`, если сменились mtime, размер или inode; новый токен —
    `offset` заново, `getMe` и `setMyCommands`. Не опрашивает, если выключен, нет токена или в `migrate.conf`
    `role=target` (после `migrate finish` запустится сам). `getUpdates` с `timeout=50`, после ответа настройки
    проверяются снова: выключили или сменили токен — апдейты не обрабатываются и не подтверждаются. Ошибки —
    пауза 1, 2, 4… до 60 с (401 — сразу 60, 429 — `retry_after`); паузу прерывает смена файлов бота (`wait`).
    409 пишется в журнал. Смена состояния — строка `бот: …` в журнале, токен вырезается (`scrub`).
    `running` ставится после `getMe` или после ответа на опрос, а после выключения с уже проверенным
    токеном — сразу, перед опросом. Выключение с Telegram заметно только после ответа на опрос (до 50 с).
  - Отвечает только админам из `bot.json` и только в личном чате; группы и каналы не читает. Сообщения старше
    запуска (или смены токена) на 5 минут пропускаются. Чужим молчит, в журнал ID и username не чаще раза в
    минуту на ID. Исключение — 64 знака hex или `/start <код>` (ссылка t.me): `iof bot redeem`, ответ «ты админ,
    роль …», «код не подошёл» или «идёт перенос»; не больше 5 кодов в минуту от одного ID, дальше молчит.
  - Команды: `/start` (приветствие, сервер, роль), `/help` (список из `COMMANDS`, он же меню `setMyCommands`).
    Сообщения в HTML (`esc`), длинные режутся по строкам на части до 4096 знаков (`send`, кнопки у последней);
    правка (`reply` → `editMessageText`) обрезает хвост по строкам, «message is not modified» не ошибка,
    сообщение, которое не исправить, заменяется новым. Каждая строка ответа с закрытыми тегами.
  - Просмотр (этап 3, ничего не меняет, обеим ролям): `/status` (сколько узлов в порядке, внимание, проблемы,
    проблемные с причиной, кнопка на каждый узел и «Обновить»), `/node <имя>` (как страница узла: адрес, SSH,
    нагрузка, Hysteria2, AWG, проблемы, ретрансляторы; кнопка «Обновить»; без имени или с неизвестным — выбор
    кнопками), `/audit` (по блокам из `iof api audit`: когда проверено, счёт, проверки crit и warn по узлам),
    `/service` (версия и клон, сразу, затем то же сообщение с итогом `iof api updates`; `check.last`, ночное
    обслуживание, нет cron — подсказка), `/hy2` (подпись группы, число ссылок, через ретранслятор, список
    портов; самих ссылок нет). Оформление — функции `*_text` модуля, пороги и слова как у страниц (`node_level`
    = `nodeLevel` из `common.js`). Время — сервера с поясом (`clock`, `stamp` с «N назад»).
  - Команды просмотра идут в потоке `iof-bot-view` (`worker`), не больше `WORKERS` = 4 сразу, иначе «повтори
    через минуту»: цикл опроса Telegram не ждёт опроса узлов. Если `cache.fresh()` ложно, сначала сообщение
    «Опрашиваю узлы…», потом оно исправляется ответом (`placeholder`). Ошибка в команде — traceback в журнал,
    админу «ошибка в боте».
  - Кнопки inline (`press`): `st` — обновить `/status`, `n:<имя>` — карточка узла новым сообщением, `nr:<имя>` —
    обновить карточку (force). Если с именем больше 64 байт, вместо него `#` и 24 знака sha256 имени
    (`node_button`, ищется по `nodes.conf`). На каждое нажатие админа `answerCallbackQuery` (на «Обновить» —
    «Опрашиваю узлы…», если кэш не свежий); узла уже нет, незнакомая кнопка — всплывающий ответ. Нажатие
    чужого (в журнал, как сообщение) и в группе — без ответа совсем. Ответ на нажатие не принят (400:
    нажатие старое, бот не работал) — нажатие пропускается.
  - Действия (этап 4): `/check`, `/hy2add Подпись [--hop|--no-hop]`, `/hy2refresh` и кнопки: под карточкой
    узла `hr:<имя>` (перезапуск Hysteria2, если она стоит), `as:` и `ad:` (проверка узла по блоку), под `/audit`
    `au:server|dpi` (все узлы), под `/hy2` `gd:<логин>` (удалить группу) и `hf` (пересобрать все). Только если в
    `bot.json` `actions` и роль `main` (`may_act`), иначе отказ «выключены, включить в панели» или «только
    главному»; кнопки действий показываются только тогда (`can_act`). Меню команд общее, обычный админ видит
    в нём и действия. Удаление узлов, перенос, `iof update`, блок-лист и смена портов — только в панели.
  - `propose` собирает шаги (`BotActions.plan`; нельзя — отказ сразу, ещё до `Jobs`, в том числе
    `not_migrating` при переносе; `check`, `audit run` и, как у панели, `hy2 restart` при переносе разрешены)
    и шлёт «что будет сделано» с кнопками `ok:<номер>` и `no:<номер>` (16 hex от `secrets`). Номера — в
    `pending`, только в памяти и только у потока опроса: привязаны к админу и сообщению, живут `CONFIRM_TTL`
    = 300 с, не больше `MAX_PENDING`. Иначе — «подтверждение устарело, повтори команду». `confirm` собирает
    шаги заново (группы уже нет, начался перенос — отказ) и ставит задачу вида `bot`; очередь занята —
    всплывающее «сейчас идёт задача «…»», номер не тратится. В журнал — кто запустил задачу.
  - Ход задачи — то же сообщение: `follow`, поток `iof-bot-job` на задачу (не слот `WORKERS`), раз в `FOLLOW`
    = 3 с правит его, если текст изменился (`job_text`: шаг, последние 10 строк лога из `jobs.list()`, итог
    словами `JOB_STATES` из `common.js`; у `check` warn — «на узлах есть проблемы»). После `hy2 add` под итогом
    кнопка ссылок группы. Бота выключили или сменили токен — сообщение больше не правится.
  - Ссылки: если `hy2_links`, в `/hy2` у группы кнопка `g:<логин>` (`#` и хэш, если не влезает в 64 байта;
    логин iof не длиннее 41 знака, так что на деле не бывает). `view_links` шлёт на каждую ссылку `sendPhoto`
    (PNG от `qr_png`, multipart — функция `multipart` модуля) с подписью «узел · группа» и ссылкой в `<pre>`;
    подпись длиннее 1024 знаков — ссылка отдельным сообщением; без qrencode или если фото не принято — только
    текст. `hy2_links: false` — кнопок ссылок нет, старая кнопка отказывает «выдача выключена в панели».
  - Клиент Bot API (`Api`) на urllib без прокси, JSON в теле, с файлами (`files`) — multipart/form-data.
    Ошибки: `ApiError` (код, текст, `retry_after`) и `NetError` (нет связи); текст без токена.
- Пароли и ключи из формы передаются в `iof` через stdin (`--password-stdin`, `--key-stdin`),
  в лог задачи пишется команда без них. Поля формы проверяются и в панели, и в `iof`.
  Поля входа на сервер разбирает `login_fields` (общая для добавления и переноса).
- **Внешний вид** описан в [`web/design.md`](web/design.md): цвета обеих тем, шрифты, размеры,
  брейкпоинты, классы. Цвета бери оттуда, а не ищи в `app.css`. Если меняешь их в `app.css`,
  обнови и `design.md` в том же изменении.
- Фронтенд на чистом JS. `common.js`: форматирование, иконки, `startPage({url, render, demo, init})`
  с автообновлением. Там же общий код форм с задачей iof: `collectLogin`, `initLoginForm`,
  `showErrors`, `formError`, `postJson`, `pageJob`, `renderJobCard`, `jobResult`, `failReason`.
  У каждой страницы своя пара `*.html` + `*.js`. Страницы: Обзор (`index.html`, `dashboard.js`),
  Hysteria2 (`hy2.*`), Безопасность (`security.*`, загрузка как на «Сервисе», без `startPage`; карточка
  `#probe` «Доступность из РФ» с этапами `probeStage`: idle, starting, wait, import, expired, foreign; пока
  проверка идёт, страница опрашивает `api/probe` раз в 2 с), Добавить сервер (`add.*`), Перенос (`migrate.*`), Узел (`node.*`, `node.html#n=<имя>`,
  открывается кликом по строке таблицы узлов; терминал на нём — `term.js`), Телеграм бот (`bot.*`, загрузка как
  на «Сервисе»; опрос `api/bot` раз в 15 с, раз в 2 с, пока бот включается или выключается — `stateView`;
  настройки и таблица админов перерисовываются, только когда поменялись; код приглашения живёт только в
  диалоге `#invite-dialog` и стирается при закрытии), Сервис (`service.*`). Опрос задачи страницы — `watchJob`
  в `common.js`, оценка узла и `meter` — тоже там. Ключи и конфиги AWG
  панель не показывает.
- Каркас страницы: `.shell` = боковое меню `aside#sidebar` (логотип, разделы «Мониторинг» и
  «Управление», внизу переключатель темы и плашка демо) + `.content` (шапка `.page-head` с `h1`,
  описанием и кнопками, `main`, подвал). Меню повторено в каждом html, у текущей страницы
  `aria-current="page"`, отметка `#nav-migrate` у «Переноса» ставится из `renderMigrate`.
  На окне уже 960px меню выезжает по кнопке `#menu-btn` (класс `nav-open` на body).
  Поведение каркаса (демо в ссылках, тема, выезжающее меню) — в `common.js`, на DOMContentLoaded.
  `common.js` подключается в `<head>` **без defer**: тема (`auto|light|dark`, `localStorage`
  `iof-web.theme`, атрибут `data-theme` на html) ставится до первой отрисовки. Остальные скрипты с defer.
- Раскладки внутри `main` подстраиваются под его ширину через container queries
  (`@container content`), а не под окно: часть ширины занимает меню. Таблица узлов на «Обзоре»
  переходит в карточки, когда содержимое уже 1000px (её минимальная ширина около 972px).
- **Демо-режим** `?demo`: данные из `demo.js` или из функций `demo*` в js страницы, сервер не нужен.
  На «Переносе» `?demo=source` и `?demo=target` показывают идущий перенос. На «Безопасности»
  `?demo=wait` — проверка с ПК ждёт отчёт (по «скачай скрипт» через несколько секунд приходит результат),
  `?demo=vpn` — проверка шла через VPN, `?demo=open` — провайдер ничего не фильтрует. На «Телеграм боте»
  `?demo=notoken`, `off`, `409`, `neterr` (нет связи), `nomodule` (модуль бота не загрузился), `migrate`;
  действия в демо меняют `demoState` (`demoPost`). Терминал в демо —
  выдуманная оболочка (`demoShell` в `term.js`, команда `help`). Демо надо
  поддерживать при изменении страниц.

## Конвенции

- Стиль кода как в окружающем: короткие функции, комментарии на русском над функцией,
  они объясняют «зачем». Сообщения пользователю — по-русски, с готовой командой, что делать дальше.
- Ошибки на управляющем сервере: `die`, на узле: `n_err` (с `[hostname]`). Служебный лог узла
  пишется в stderr, результат — в stdout.
- Секреты: файлы 600, каталоги 700. Секреты не передаются в аргументах команд (только stdin).
  Перед изменением конфигов на узле делается бэкап.
- Операции идемпотентны: повтор после частичной ошибки безопасен и не создаёт дублей.
- Проверка входных данных: `node_name_ok`, `host_ok` (IPv4 или имя, **IPv6 не поддерживается**,
  потому что `:` занят под порт), `user_ok`, `port_ok`, `title_ok` (без `|`).
- Переводы строк только LF (`.gitattributes`: `* text=auto eol=lf`).
- Коммиты: на русском, в формате `компонент: что сделано` (`iof-web: добавление сервера из панели`).

## Проверка изменений

Минимум после правок — статические проверки (работают и в Git Bash):

```bash
bash ci/lint.sh
```

На машине разработки нет shellcheck и Python, эти проверки там пропускаются (`skip`), в CI они
обязательны. Полностью, как в CI, `lint.sh` можно прогнать в контейнере Ubuntu 24.04 в WSL с
`apt install shellcheck pyflakes3 nodejs git` и `CI=true`.

**CI** (`.github/workflows/ci.yml`, GitHub Actions) запускается на push в master, на PR и вручную.
Задача `lint` выполняет `ci/lint.sh` (shellcheck с `--severity=warning`, pyflakes ставится через
pipx). Задача `stand` поднимает на раннере стенд из двух серверов, `old` (управляющий и узел)
и `node1` (узел): `stand.sh up old node1`, `setup`, `test`. При ошибке печатает журналы серверов,
итоги `test` видны на странице запуска. Секретов у workflow нет, на настоящие серверы он не ходит:
обновление управляющего сервера по-прежнему `iof update`.

`stand/test.sh` (`stand.sh test [управляющий сервер]`) проверяет: все узлы на связи и без проблем,
`iof exec` и `iof check`, группу Hysteria2 (по ссылке на каждый узел клиент Hysteria2 с другого
сервера открывает `PROBE_URL` через туннель, ссылка с неверным паролем получает отказ авторизации),
ретранслятор (`relay add`, туннель через него, `relay del`), `hy2 restart`, смену портов (`hy2 hop on all`,
повтор ничего не меняет; на первом узле, который не управляющий сервер, входящие запрещены политикой DROP;
по ссылке группы `--hop` клиент на другом сервере с `hopInterval 5s` открывает `PROBE_URL`, где правила в
iptables, счётчик перехода показывает несколько потоков; заход на порт из диапазона; `hy2_hop` — `good`,
`listen` не считается расхождением с шаблоном, `refresh` не теряет диапазон; `hop off all` — один порт,
ссылки рабочие, на узлах нет правил и drop-in; включение и выключение задачей панели, `all` панель не
принимает), аудит (`audit run` по всем
узлам, вход по паролю на стенде — проблема; на первом узле, который не управляющий сервер: лишний
слушатель на 18080 попадает в «лишние» и `audit cron` сообщает об ухудшении, `PasswordAuthentication no`
снимает проблему, узел с остановленным ssh остаётся без оценок), блок dpi (у каждого узла конфиг
Hysteria2 совпадает с шаблоном, порт отвечает на зонд QUIC, AmneziaWG — `none` «не установлен»;
после правки конфига на узле проверка видит расхождение с шаблоном и `audit cron` сообщает о нём,
после возврата конфига расхождения нет; пароля Hysteria2 нет в `/root/iof/audit`, `audit show`
и `api audit`), блок-лист (на первом узле, который не управляющий сервер; список раздаёт управляющий сервер
`python3 -m http.server` на 127.0.0.1; другой сервер на время каждого захода получает адрес 1.2.3.4 из списка
или 1.2.3.5 из `BLOCK_ALLOW` (не раньше: если это управляющий сервер, `iof block` взял бы его адреса в
«не блокировать»), узел ходит к ним через него: с 1.2.3.4 пакеты отбрасываются, с 1.2.3.5, с адреса из `nodes.conf` и
с управляющего сервера — нет; IPv6, частные и слишком широкие записи и мусор пропущены; после
перезапуска `iof-block` список на месте; `block update` с тем же списком ничего не меняет; `blocklist` —
`good`; обновление и снятие задачей панели, после снятия нет наборов, правил и файлов), запрет действий
при переносе (поддельный `migrate.conf`: `hy2 hop`, `block`, `hy2 upgrade` и действие в панели отказаны,
`audit run` разрешён), Telegram-бота через поддельный Bot API (только если на управляющем сервере служба
`fake-tg` и `IOF_TG_API` на неё: `bot.json` и `bot.token` сохраняются и возвращаются; `bot on` без токена,
неверный и отозванный токен — отказ; бот опрашивает API, меню из всех команд; чужому молчит, в журнал
ID и username; неверный, повторный, просроченный код и код из группы не приняты, верный и `/start <код>`
приняты с ролью; старое сообщение пропущено; `/start` и `/help` админу, в группе не отвечает и ему;
`invite del`, `admin set|del`, `set`; страница бота: `/api/bot` без токена, у приглашения только начало
хэша и без кода, настройки, неверные тихие часы и POST без `X-IOF-Request` отказаны, приглашение из панели
отзывается и принимается ботом, кодов нет в журнале, роль, звук и удаление админа, отозванный токен не
принят, верный принят, выключатель; команды просмотра у обычного админа: `/status` сначала «опрашиваю
узлы…», потом то же сообщение с кнопками узлов и «Обновить», кнопка узла — карточка новым сообщением и
`answerCallbackQuery`, «Обновить» у карточки и у `/status` — `editMessageText` того же сообщения, повторное
«Обновить» с теми же данными без ошибки, `/node` с узлом, без имени и с неизвестным, `/audit`, `/service`,
`/hy2`, `/help`; нажатие чужого (в журнал) и в группе без ответа, незнакомая кнопка; узел с длинным именем
(временная строка в `nodes.conf`, адрес из TEST-NET): в кнопке хэш, карточка «нет связи», после удаления
строки — «узла больше нет»; в ответах нет паролей Hysteria2, ключей AWG и токена; действия: отказ при
выключенных действиях и обычному админу (и на его нажатие старой кнопки), кнопки действий только главному,
«Отмена», повторное, чужое (другого админа), истёкшее (модуль бота в процессе теста) и после перезапуска панели
нажатие «Подтвердить» — «устарело», занятая очередь (задача панели) и то же «Подтвердить» после неё, ход задачи
правками одного сообщения до итога, перенос (`/hy2add` отказан сразу, полученное до него подтверждение — тоже,
`/check` разрешён), перезапуск Hysteria2 и аудит узла кнопками, группа `CI бот` из бота (подтверждение, задача,
кнопка ссылок под итогом), её ссылки — `sendPhoto` с PNG на каждую и без qrencode только текстом, `hy2_links`
выключено, удаление группы (её нет в `index.tsv`, кнопка ссылок — «группы больше нет»); паролей Hysteria2 нет
в журнале и логах задач, но они есть в ответах админу; 409 от второго опроса в журнале, бот продолжает; при `role=source`
изменения (и из панели) и коды отказаны, при `role=target` бот не опрашивает API и `/api/bot` показывает
`migrate`, без переноса отвечает на ждавшее сообщение; `off` и пустой токен; токена нет в журналах,
`bot.json` и `show`), проверку с ПК (мишени на узлах с python3 и «не проверяется» на узле без него; на первом
узле с python3, который не управляющий сервер, входящие запрещены политикой DROP — мишень открывает
порт двумя правилами; контроль проходит все слои; мишень отвечает по TLS и UDP только с токеном; готовый
JSON: TCP не проходит — `crit` с высокой уверенностью, IP источника — адрес узла — всё `none` и низкая,
отчёт с токеном и от другой проверки не принимаются; токена нет в выводе и результатах; после `stop`
и по `RuntimeMaxSec` на узлах нет юнитов, папок в `/run` и правил), панель (страницы, `/api/security` с
обоими блоками и проверка узла задачей панели по каждому блоку,
`/api/dashboard`, отказ при чужом `Host`, без `X-IOF-Request` и с чужим `Origin`, создание и удаление
группы задачей панели; проверка с ПК: билет, скрипт по билету один раз и с данными проверки, отказ
по неверному билету и чужому `Host`, отчёт без пароля и `Origin` принят, без `X-IOF-Request` и по
неверному или повторному билету — нет, после отчёта результат есть, мишени остановлены, токена нет
в ответах панели и логах задач), терминал на каждый узел (WebSocket, размер окна при открытии и после resize,
команда, код выхода; отказ при повторном билете, неверном билете и чужом `Origin`; терминал включает
`stand.sh setup`). Всё созданное удаляет, в том числе при обрыве. Узлы в `nodes.conf` должны
называться как контейнеры. Интерфейс проверяется в демо-режиме (`index.html?demo` и другие страницы). Встроенный браузер не открывает `file://`,
поэтому `web/static` надо раздать любым статическим сервером на Node; удобно отдавать ту же CSP,
что у `iof-web`, тогда сразу видны inline-стили.

Скриншоты для README все в тёмной теме. На виду `docs/panel-overview.png` (`index.html?demo`) и
`docs/panel-node.png` (`node.html?demo#n=node-4`), под спойлером `<details>` — `panel-hy2.png`
(`hy2.html?demo`), `panel-security.png` (`security.html?demo`), `panel-terminal.png` и `panel-add.png` (`add.html?demo`). Снимаются Chrome без окна
с демо-страниц, раздаваемых статическим сервером. Окно 1360×860 (так таблица узлов ещё не превращается
в карточки), масштаб 1.5, тёмную тему задаёт `--force-dark-mode`, а `--virtual-time-budget` даёт
демо-данным загрузиться:

```bash
chrome --headless=new --hide-scrollbars --window-size=1360,860 --force-device-scale-factor=1.5 --virtual-time-budget=5000 --force-dark-mode --screenshot=docs/panel-overview.png "http://localhost:8099/index.html?demo"
```

Терминал так не снять: его надо открыть и набрать команды. Для `panel-terminal.png` Chrome запускается
с `--remote-debugging-port`, и через DevTools Protocol на `node.html?demo#n=node-2` с теми же размером
и масштабом (`Emulation.setDeviceMetricsOverride`, тема — `Emulation.setEmulatedMedia`) нажимается
`#term-open`, в демо-оболочку вводятся `uptime`, `df -h`, `free -h`, `ls` (`Input.dispatchKeyEvent`),
карточка `#term` прокручивается в окно, затем `Page.captureScreenshot`. Node 22+ умеет это без пакетов
(встроенные `fetch` и `WebSocket`).

**Тестовый стенд** (`stand/`, Docker Engine в WSL Ubuntu-24.04) — для проверки по-настоящему:
четыре «сервера» Ubuntu 24.04 с systemd и SSH в сети 172.30.0.0/24, пароль root `stand`.
`old` (.10) — управляющий сервер и узел, `node1` (.11) и `node2` (.12) — узлы, `new` (.20) —
чистый сервер для переноса. SSH на них из WSL и Windows: 127.0.0.1:2201–2204.

Из Windows команды стенда запускаются так (в Git Bash перед этим `export MSYS_NO_PATHCONV=1`):

```bash
wsl -d Ubuntu-24.04 -u root --cd /mnt/c/dev/repos/iof -- bash stand/stand.sh up
```

```bash
bash stand/stand.sh up        # собрать и поднять; up old node1 — только эти серверы, как в CI
bash stand/stand.sh setup     # iof из рабочей копии на old, поднятые узлы, Hysteria2, группа ссылок, cron, терминал, python3 на node1, nftables и fake-tg на old
bash stand/stand.sh test      # проверка iof на стенде (stand/test.sh); после переноса: test new
bash stand/stand.sh sync      # после правок: залить рабочую копию на серверы, где стоит iof
bash stand/stand.sh tunnel    # панели: old http://localhost:8081/, new http://localhost:8082/
bash stand/stand.sh probe start   # VPN-клиент на node2 через Hysteria2 на old, проверка связи раз в 2 с
bash stand/stand.sh probe show
bash stand/stand.sh pc on new     # проверка с ПК с Windows против стенда, печатает $env:IOF_PROBE_MAP
bash stand/stand.sh pc off
bash stand/stand.sh iof old status
bash stand/stand.sh down
```

Особенности:
- WSL гасит Ubuntu (а с ней Docker), когда в ней не остаётся сессий `wsl.exe`. Пока стенд нужен,
  держи сессию открытой (например, `wsl -d Ubuntu-24.04 -u root -- sleep infinity` в фоне). У
  серверов `restart: unless-stopped`, после следующего запуска Docker они поднимутся сами.
- `wsl.exe ... -- команда` пропускает команду через оболочку Ubuntu: `$(...)` в аргументах
  раскроется в WSL, а не в контейнере. Скрипты для контейнера передавай через stdin
  (`docker compose exec -T old bash -s <<'EOF'`).
- Туннели (`stand.sh tunnel`) поднимаются в WSL, порты 8081/8082 видны и из Windows: встроенный
  браузер открывает их через записи `stand-old-panel` и `stand-new-panel` в `.claude/launch.json`.
- `machine-id` во всех контейнерах одинаковый, как у VPS из одного образа. iof на него не опирается.
- Hysteria2 ставится официальным установщиком, поэтому `setup` нужен интернет. `test` тоже:
  через туннели открывается `PROBE_URL` (по умолчанию `generate_204` от Google). AmneziaWG на стенде
  нет: ему нужен Docker внутри сервера.
- Клиент Hysteria2 понимает ссылку `hy2://` прямо в поле `server` конфига, а формат файла
  конфига определяет по расширению: файл без `.yaml` не прочитается.
- Ретранслятор `test` проверяет клиентом на самом узле: пакеты уходят на ретранслятор и через DNAT
  возвращаются на узел. С самого ретранслятора так нельзя: свои пакеты не проходят PREROUTING.
- Ключ для туннелей хранится в `~/.iof-stand` в WSL: с `/mnt/c` ssh ключ не берёт, там права 777.
- python3 для мишеней проверки с ПК `setup` ставит только на node1: node2 остаётся без него, и `test`
  проверяет оба случая. В CI (old и node1) случая «нет python3» нет, `test` об этом пишет.
  `setup` же пишет в `iof.env` управляющего сервера `PROBE_PORTS=47000`.
- `setup` ставит на old `nftables`: Hysteria2 тогда пробует правила смены портов через nft. В ядре WSL
  нет `CONFIG_NFT_FIB_IPV6`, правило для ip6 не встаёт, служба падает, и iof переходит на iptables — так
  стенд проверяет этот откат. В CI (ядро Azure) на old должны встать правила nftables. Счётчика
  потоков у них нет, поэтому `test` проверяет на таком узле только туннели.
- Все адреса стенда частные, а частные сети блок-лист не применяет. Поэтому `test` даёт проверяемому узлу
  маршрут к 1.2.3.0/24 через другой сервер, а тому — адрес 1.2.3.4 или 1.2.3.5 на время одного захода.
- В CI управляющий сервер `old` сам узел, и другого сервера для захода, кроме него, нет. Поэтому тесты не
  оставляют на нём чужих адресов (`hostname -I` попадает в «не блокировать»), а в готовых отчётах проверки
  с ПК IP источника — выдуманный адрес ПК, а не адрес управляющего сервера из контроля (иначе «через VPN»).
- Проверка с ПК с Windows: WSL в режиме NAT пересылает на 127.0.0.1 только TCP, UDP доходит лишь до
  адреса WSL, а сеть 172.30.0.0/24 из Windows не видна. `stand.sh pc on [управляющий]` ставит в WSL DNAT
  (комментарий `iof-stand-pc`): порт `470NN` на мишень `172.30.0.NN:47000` по TCP и UDP, `471NN` на 443/udp
  (Hysteria2), и ACCEPT в `DOCKER-USER`; печатает `$env:IOF_PROBE_MAP` для `probe.ps1`. Адрес WSL меняется
  при перезапуске WSL, тогда `pc on` заново; `pc off` убирает правила. Панель для ПК — через `stand.sh tunnel`.
- Бот на old ходит не в Telegram, а в поддельный Bot API: `setup` ставит службу `fake-tg`
  (`stand/fake-tg.py` на 127.0.0.1:8089, `--max-wait 5`: `getUpdates` ждёт не дольше 5 с, и тесты быстро
  видят, что бот выключили) и пишет `IOF_TG_API=http://127.0.0.1:8089` в `web.env`. Токен с номером бота 0
  поддельный API считает отозванным. Служебный вход `/fake/*` — подложить сообщение или готовый апдейт
  (нажатие кнопки — `callback_query` через `/fake/update`, номер сообщения бота есть в `/fake/sent`), забрать
  отправленное, состояние опроса (описан в начале `fake-tg.py`). Как Telegram, отвечает 400 на `callback_data`
  длиннее 64 байт, больше 100 кнопок, правку неизвестного сообщения и правку без изменений
  («message is not modified»), `sendPhoto` без файла и с подписью длиннее 1024 знаков. Файл из multipart в
  журнале вызовов — `{filename, size}`. Проверка ссылок без QR на время захода переименовывает `qrencode`
  на old в `qrencode.iof-test` (cleanup возвращает). `sync` перезапускает `fake-tg`. Живой бот на стенде:
  убрать `IOF_TG_API` из `web.env`, `systemctl restart iof-web`, токен через `iof bot token` со stdin.
- Git Bash на машине разработки может сломаться при обновлении Git for Windows (пустой `usr\bin`):
  тогда `lint.sh` и скрипты стенда запускаются из WSL (`wsl -d Ubuntu-24.04 -u root -- bash ci/lint.sh`).

## Неочевидные места

- Смена портов Hysteria2 пишется в `listen` как `:443,10000-19999`, а не `:10000-19999`: Hysteria2
  слушает первый порт списка, и с одним диапазоном основной порт стал бы 10000, а выданные ссылки и
  DNAT ретрансляторов на 443 перестали бы работать. `n_hy2_port` и так берёт первый порт.
- Правила смены портов ставит не iof, а сама Hysteria2 при запуске, и снимает при остановке. После
  падения на iptables осталась бы цепочка `HYSTERIA-PR-*`, и служба не запустилась бы (`-N` с ошибкой):
  поэтому drop-in `iof-hop.conf` перед стартом чистит остатки. Он же удаляет таблицы `hysteria_*` других
  экземпляров `hysteria-server@*`, если они есть.
- Блок-лист стоит в raw PREROUTING, а не в INPUT: в INPUT не попадает трафик к портам контейнеров Docker
  (AmneziaWG) и ретранслятора, он идёт через FORWARD после DNAT. Частные сети список не блокирует:
  через raw PREROUTING идут и пакеты контейнеров Docker с их внутренних адресов.

- `iof-nightly` считает сервер управляющим по наличию `/usr/local/bin/iof`: там задание ждёт
  5 минут, пока оно разойдётся по остальным узлам. Поэтому `migrate finish` удаляет `iof`
  со старого сервера, а задания cron переносит только на этом этапе: иначе обслуживание
  запускалось бы с двух серверов.
- `iof hy2 install` завершается с кодом 0, даже если на части узлов была ошибка. Панель
  распознаёт это по строке `Ошибки (` и ставит задаче состояние `warn`.
- В `iof-web.service` `--listen` задан явно, поэтому `IOF_WEB_LISTEN` из `web.env` не действует.
- `HY2_TEMPLATE` читается из двух мест: `iof` берёт его из `iof.env`, а панель — из `web.env`.
  Если задать его только в `iof.env`, панель не даст установить Hysteria2 при добавлении сервера,
  когда на управляющем сервере нет `/etc/hysteria/config.yaml`.
- `cmd_node_add` перед `onboard_nodes` делает `exec </dev/null`, чтобы ssh в фоновых задачах
  не читал stdin.
- `iof node del` не трогает сам сервер и отказывается удалять узел, который участвует в ретрансляторе.
  После удаления нужен `iof refresh`.
- Ссылка через ретранслятор — это ссылка узла с адресом и портом ретранслятора. AWG-конфиг через
  ретранслятор отличается от конфига узла только `Endpoint`.

## Планы и обсуждения

- Telegram-бот (ветка `feat-telegram-bot`): план по этапам и согласованные решения в [`bot-plan.md`](bot-plan.md).
  Каждый этап — отдельный чат: начни с этого файла, в конце отметь этап в нём.
- VLESS: заглушка `cmd_vless`, команд пока нет.
- Перенос управляющего сервера (`iof migrate`, страница «Перенос») реализован и прогнан на стенде
  через панели: перенос по паролю, повтор, отмена, повторный перенос, завершение. VPN-клиент через
  старый сервер не прервался ни разу. Не проверены на стенде: `--skip-old`, вход по ключу,
  пользователь не root. Ключ iof при переносе копируется, а не перевыпускается: смену ключа
  можно сделать отдельной командой.
