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
| `web/iof-web.service` | systemd-юнит панели | `/etc/systemd/system/iof-web.service` |
| `web/static/*` | страницы панели: html, js, css. Без подкаталогов: `install.sh` копирует `web/static/*` плоско | `/opt/iof-web/static/` |
| `web/static/xterm.js`, `xterm-fit.js`, `xterm.css` | сторонний код для терминала: `@xterm/xterm` 6.0.0 и `@xterm/addon-fit` 0.11.0 из npm, см. «Терминал» | `/opt/iof-web/static/` |
| `web/design.md` | цвета, шрифты, размеры, брейкпоинты и классы панели | не ставится |
| `docs/panel-*.png` | скриншоты панели для README в тёмной теме: два на виду, четыре под спойлером; сняты в демо-режиме (см. «Проверка изменений») | не ставится |
| `README.md` | инструкция для пользователя | — |
| `stand/` | тестовый стенд на Docker: `Dockerfile` (Ubuntu 24.04 с systemd и SSH), `compose.yml` (old, node1, node2, new), `stand.sh`, `test.sh` (проверка iof на стенде), `hy2-template.yaml` | не ставится; попадает в `/opt/iof` как часть клона |
| `ci/lint.sh` | статические проверки: `bash -n`, shellcheck, разбор и pyflakes для `iof-web.py`, `node --check`, правила проекта (NODE_FUNCS, STATIC_FILES, CSP, одинаковое меню во всех html, LF) | не ставится |
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
| `iof.env` | bash, читается через `source`: `TG_TOKEN`, `TG_CHAT`, `PARALLEL`, `IOF_SRC`, `HY2_TEMPLATE`, `HY2_CN` (CN сертификата для `hy2 install`, если сертификата из шаблона здесь нет), `AUDIT_KEEP`, `BLOCKLIST_URL` и `REGISTRY_URL` (списки для блока dpi: текст, IP или CIDR в строке, `#` — комментарий; по умолчанию пусто) |
| `web.env` | EnvironmentFile панели: `IOF_WEB_PASSWORD`, `IOF_WEB_HOSTS`, `IOF_WEB_TTL`, `IOF_WEB_TERMINAL` (`1` включает терминал), а также `HY2_TEMPLATE`, `IOF_BIN`, `IOF_BASE`, `IOF_SSH_KEY` |
| `state/<узел>` | последнее состояние для `iof check`: `ok` или текст проблем |
| `hy2/index.tsv` | `логин<TAB>подпись<TAB>создан` |
| `hy2/<логин>.txt` | ссылки группы по строке: узлы, затем ретрансляторы; внутри пароли |
| `awg/index.tsv` | как у hy2 |
| `awg/<логин>/<Подпись>.conf` | конфиг клиента для узла, с **приватным ключом клиента** (больше нигде его нет) |
| `awg/<логин>/<Подпись>.pub` | `публичный_ключ контейнер` |
| `awg/<логин>/*_via_*.conf`, `keys.txt` | пересобираются при каждом `awg keys`/`refresh` |
| `check.last` | итог последнего `iof check` для панели: `time`, `total`, `bad`, `problems` (имена через пробел), `changes` |
| `audit/server.json`, `audit/dpi.json` | последняя проверка блока `iof audit` по узлам: `{"nodes": {имя: {addr, reachable, at, checked, error, checks: [{id, status, value, detail, hint, cmd}]}}}`. Проверка одного узла заменяет только его запись |
| `audit/history.jsonl` | строка JSON на запуск `iof audit run`: `at`, `block` (`server`, `dpi` или `all`), `nodes`, `counts`, `down`, `worse`; хранится `AUDIT_KEEP` последних (по умолчанию 30, задаётся в `iof.env`) |
| `audit/cache/` | для блока dpi: `blocklist.txt` и `registry.txt` (списки по `BLOCKLIST_URL` и `REGISTRY_URL`, рядом `.url` — откуда скачан, `.err` — последняя загрузка не удалась) и `whois-<адрес>.txt` (`состояние\|AS\|организация\|страна`). Всё обновляется не чаще раза в сутки |
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
- AmneziaWG: docker-контейнер `amnezia-awg2` или `amnezia-awg` (ставит приложение Amnezia VPN),
  конфиг `/opt/amnezia/awg/{awg0|wg0}.conf` внутри контейнера, `clientsTable` ведётся как
  в приложении. Бэкапы перед изменением: `/var/backups/iof-awg` на хосте.
- Ретранслятор: `/etc/iof/relay.rules`, `/usr/local/sbin/iof-relay`, `iof-relay.service`,
  `/etc/sysctl.d/99-iof-relay.conf`. Работает на iptables DNAT+MASQUERADE в цепочках `IOF-*`.
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
  (список в `case "$cmd:${1:-}"`); `exec`, `check`, `status`, `update` и просмотр разрешены.
  При добавлении новой меняющей команды её нужно внести в этот список.

- **Аудит безопасности** (`iof audit`, этапы 1 и 2 из плана `security-plan.md`). Блоков два:
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
    Блок-лист iof не применяет, а проверяет то, что будет применять этап 4: набор ipset `iof-block`,
    цепочка `IOF-BLOCK` с переходом из INPUT, время списка — `/etc/iof/block.list` на узле.
    Port hopping: диапазон в `listen` или REDIRECT/DNAT диапазона на порт Hysteria2; цепочки `IOF-*`
    ретранслятора при этом не учитываются.
- Не сделано: проверка доступности с ПК (этап 3), действия вроде включения port hopping и применения
  блок-листа (этап 4). Не проверено: разбор конфига AWG на живом контейнере (на стенде AmneziaWG нет,
  проверен на подставном конфиге в формате `awg0.conf` контейнера `amnezia-awg2`), GET по HTTP/3,
  whois для адреса узла целиком (помощник проверен на публичных адресах отдельно), CrowdSec.

Команды: `status`, `check` (для cron, Telegram, пишет `check.last`), `exec`, `refresh`, `init`,
`api status|service|updates|audit` (audit — JSON), `audit run [server|dpi|all]|show|cron`, `update`, `version` (версию подставляет `install.sh` в `IOF_VERSION`),
`node add|import|del|list`, `hy2 install|add|del|list|show|refresh|status|restart`,
`awg add|keys|del|show|export|list|clients|refresh|status`, `relay add|del|list|apply`,
`migrate start|finish|cancel|status`, `vless` (заглушка, WIP). Полный список в `usage()`.

## Веб-панель `iof-web`

- `ThreadingHTTPServer` на `127.0.0.1:8088`, работает от root. Открывается через SSH-туннель.
  Слушать не на loopback без `IOF_WEB_PASSWORD` откажется (HTTP Basic, имя пользователя любое).
- **Читает** файлы `/root/iof` напрямую. **Меняет** что-либо только через команды `iof`
  в классе `Jobs`: одна задача за раз, лог в памяти (10 задач, 600 строк, 900 с на шаг).
  Единственное исключение — терминал на узел (`Terminals`, см. ниже), он выключен без `IOF_WEB_TERMINAL=1`.
  У задачи есть вид `kind` (`node` — добавление, `migrate`, `hy2`, `service`, `node:<имя>` — действия
  с узлом): по нему страница находит свои задачи. Ссылки `hy2://` в логе задачи без пароля (`HY2_SECRET`).
  По завершении задачи кэш статуса сбрасывается. Если в выводе есть строка, начинающаяся
  с `Ошибки (`, задача получает состояние `warn`: так поступают `hy2 install`, `migrate start`
  и `migrate cancel`. То же для строк из `WARN_LINES` (`hy2 add/del/refresh` не на всех узлах).
- Статус узлов: `StatusCache` запускает `iof api status`, держит ответ `IOF_WEB_TTL` секунд
  (по умолчанию 20). `force` обновляет не чаще раза в 5 с, таймаут 180 с.
- API: `GET /api/dashboard`, `/api/hy2`, `/api/hy2/qr?g=<логин>&i=<n|all>`, `/api/nodes/add-info`,
  `/api/migrate`, `/api/node?n=<имя>`, `/api/service[?fetch=1]` (через `iof api service|updates` и логи
  `/var/log/iof-nightly*.log`), `/api/jobs`, `/api/term/ws?t=<билет>` (WebSocket терминала);
  `POST /api/nodes` (добавление сервера, при необходимости
  `iof hy2 install`), `POST /api/migrate` (`action`: start, finish или cancel), `POST /api/hy2`
  (`add|del|refresh`), `POST /api/node` (`restart_hy2|install_hy2|delete`, удаление = `node del` + `refresh`),
  `POST /api/term` (`{name, cols, rows}` → одноразовый билет терминала),
  `GET /api/security` (вывод `iof api audit` плюс `error`, `busy`, `migrate`; узлы не опрашивает) и
  `POST /api/security` (`{block: "server" | "dpi", node}` → задача вида `audit`:
  `iof [-n узел] audit run <блок>`; блоки перечислены в `AUDIT_BLOCKS`. Страница «Безопасность»,
  `security.html` + `security.js`: у каждого блока из `BLOCKS` свои `#<блок>-node`, `-run`, `-stamp`,
  `-health`, `-checks`, отрисовка общая (`renderBlock`); демо-данные обоих блоков в `security.js`),
  `POST /api/service` (`update`: `iof update` через `systemd-run --pipe --wait`, потому что install.sh
  перезапускает панель; вывод через `tee -p` ещё и в `/var/log/iof-update.log`, без этого `iof update`
  падал с кодом 1 на записи в оборванную трубу. Страница «Сервис» ждёт перезапуска, сравнивает
  версию и показывает вывод из этого файла).
  Состояние переноса (`read_migrate`, поле `migrate`) есть в ответах dashboard, hy2, add-info
  и migrate; `renderMigrate` в `common.js` показывает по нему плашку `#migrate-banner`.
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
  Hysteria2 (`hy2.*`), Безопасность (`security.*`, загрузка как на «Сервисе», без `startPage`), Добавить сервер (`add.*`), Перенос (`migrate.*`), Узел (`node.*`, `node.html#n=<имя>`,
  открывается кликом по строке таблицы узлов; терминал на нём — `term.js`), Сервис (`service.*`). Опрос задачи страницы — `watchJob`
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
  На «Переносе» `?demo=source` и `?demo=target` показывают идущий перенос. Терминал в демо —
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
ретранслятор (`relay add`, туннель через него, `relay del`), `hy2 restart`, аудит (`audit run` по всем
узлам, вход по паролю на стенде — проблема; на первом узле, который не управляющий сервер: лишний
слушатель на 18080 попадает в «лишние» и `audit cron` сообщает об ухудшении, `PasswordAuthentication no`
снимает проблему, узел с остановленным ssh остаётся без оценок), блок dpi (у каждого узла конфиг
Hysteria2 совпадает с шаблоном, порт отвечает на зонд QUIC, AmneziaWG — `none` «не установлен»;
после правки конфига на узле проверка видит расхождение с шаблоном и `audit cron` сообщает о нём,
после возврата конфига расхождения нет; пароля Hysteria2 нет в `/root/iof/audit`, `audit show`
и `api audit`), панель (страницы, `/api/security` с обоими блоками и проверка узла задачей панели
по каждому блоку,
`/api/dashboard`, отказ при чужом `Host`, без `X-IOF-Request` и с чужим `Origin`, создание и удаление
группы задачей панели), терминал на каждый узел (WebSocket, размер окна при открытии и после resize,
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
bash stand/stand.sh setup     # iof из рабочей копии на old, поднятые узлы, Hysteria2, группа ссылок, cron, терминал
bash stand/stand.sh test      # проверка iof на стенде (stand/test.sh); после переноса: test new
bash stand/stand.sh sync      # после правок: залить рабочую копию на серверы, где стоит iof
bash stand/stand.sh tunnel    # панели: old http://localhost:8081/, new http://localhost:8082/
bash stand/stand.sh probe start   # VPN-клиент на node2 через Hysteria2 на old, проверка связи раз в 2 с
bash stand/stand.sh probe show
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

## Неочевидные места

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

- VLESS: заглушка `cmd_vless`, команд пока нет.
- Перенос управляющего сервера (`iof migrate`, страница «Перенос») реализован и прогнан на стенде
  через панели: перенос по паролю, повтор, отмена, повторный перенос, завершение. VPN-клиент через
  старый сервер не прервался ни разу. Не проверены на стенде: `--skip-old`, вход по ключу,
  пользователь не root. Ключ iof при переносе копируется, а не перевыпускается: смену ключа
  можно сделать отдельной командой.
