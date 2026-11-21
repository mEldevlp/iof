#!/usr/bin/env bash

# iof (Island of Freedom): управление группой VPN-серверов с одного управляющего сервера
# Запускается только на управляющем сервере
# Протоколы: Hysteria2 (iof hy2), AmneziaWG 2.0 (iof awg)
set -euo pipefail

# Модули подключаются до разбора команд; build.sh встраивает их в один устанавливаемый файл.
IOF_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$IOF_LIB/common.sh"
# shellcheck source=lib/remote.sh
source "$IOF_LIB/remote.sh"
# shellcheck source=lib/node.sh
source "$IOF_LIB/node.sh"
# shellcheck source=lib/hy2.sh
source "$IOF_LIB/hy2.sh"
# shellcheck source=lib/awg.sh
source "$IOF_LIB/awg.sh"
# shellcheck source=lib/relay.sh
source "$IOF_LIB/relay.sh"
# shellcheck source=lib/block.sh
source "$IOF_LIB/block.sh"
# shellcheck source=lib/audit.sh
source "$IOF_LIB/audit.sh"
# shellcheck source=lib/probe.sh
source "$IOF_LIB/probe.sh"
# shellcheck source=lib/bot.sh
source "$IOF_LIB/bot.sh"
# shellcheck source=lib/migrate.sh
source "$IOF_LIB/migrate.sh"
# shellcheck source=lib/status.sh
source "$IOF_LIB/status.sh"
# shellcheck source=lib/service.sh
source "$IOF_LIB/service.sh"
# shellcheck source=lib/setup.sh
source "$IOF_LIB/setup.sh"
# shellcheck source=lib/api.sh
source "$IOF_LIB/api.sh"
unset IOF_LIB

usage() {
  cat <<'EOF'
Island of Freedom управление VPN-серверами // by meldevlp

Общее
  iof setup [--template-only]  мастер первого запуска; --addr IPv4/домен, --name main,
                              --title подпись, --port 443, --obfs none|salamander
  iof status                  сводная таблица по узлам
  iof check                   проверка для cron, уведомление в Telegram при изменениях; раз в сутки ещё
                              обновления iof и доступ к российским серверам с узлов (RU_TARGETS), --daily — сейчас
  iof notify тип [текст]      уведомление в Telegram (без текста — со stdin), типы: nodes audit nightly updates ru admins
  iof exec "команда"          выполнить команду на узлах
  iof refresh                 пересобрать все ссылки hy2 и ключи awg
  iof init                    первичная настройка управляющего сервера
  iof api status|service|updates   данные для веб-панели в виде key=value (api audit — JSON)
  iof update [--no-web]       обновить iof и веб-панель с GitHub (клон в /opt/iof)
  iof version                 установленная версия (коммит и дата)

Узлы
  iof node import файл        добавить много серверов по паролям root (строки: имя | ip | пароль | подпись | ssh_порт)
  iof node add имя ip [подпись] [порт]   добавить один сервер, пароль спросит
      --user mel                вход не под root (нужен sudo без пароля)
      --key файл                вход SSH-ключом вместо пароля
      --key-installed           ключ iof (/root/.ssh/iof_ed25519.pub) уже добавлен на сервер
      --addr адрес              адрес для клиентов, если отличается от адреса SSH
  iof node list               список узлов
  iof node del имя            убрать узел из списка (сервер не трогает)
  iof node rename имя новое   переименовать узел в iof (сервер не трогает)

Hysteria2
  iof hy2 install all         поставить на все узлы, где её нет (конфиг по образцу этого сервера)
  iof hy2 install de-1 'nl-*' на выбранные узлы, --force перезапишет конфиг и там, где уже стоит
  iof hy2 add "Подпись"       создать группу ссылок по всем узлам (повтор пересобирает её)
      --hop / --no-hop          список портов в ссылках группы для узлов со сменой портов: такие ссылки
                                импортируют Hiddify с 5.5.5 и официальный клиент, v2rayN и старые Hiddify — нет
  iof hy2 del "Подпись"       удалить группу
  iof hy2 list                список групп
  iof hy2 show "Подпись"      показать ссылки группы
  iof hy2 refresh             пересобрать все группы
  iof hy2 status              состояние Hysteria2 на узлах
  iof hy2 restart узлы        перезапустить Hysteria2 (all — на всех) и проверить, что поднялась
  iof hy2 hop on узлы         смена портов (port hopping): диапазон HY2_HOP (10000-19999) в listen узла,
                              основной порт и выданные ссылки остаются; --ports a-b — свой диапазон
  iof hy2 hop off узлы        вернуть один порт
  iof hy2 upgrade узлы        обновить Hysteria2 официальным установщиком, при неудаче вернуть прежнюю

AmneziaWG 2.0
  iof awg install <узлы|all> [--port 51820]
                              установить AWG на узлы и добавить их к существующим клиентам
  iof awg add "Имя"           создать клиента на всех узлах и выдать ключи vpn://
  iof awg keys "Имя"          снова показать ключи
  iof awg del "Имя"           удалить клиента со всех узлов
  iof awg show "Имя" [France] показать конфиги и QR-коды
  iof awg export "Имя"        скопировать конфиги в домашнюю папку для WinSCP
  iof awg list                клиенты, созданные через iof
  iof awg clients             все клиенты на каждом сервере с проверкой дублей
  iof awg refresh             пересобрать ключи всех клиентов
  iof awg status              состояние AmneziaWG на узлах

VLESS
  iof vless                   в разработке (WIP)

Ретрансляторы (для hy2 и awg сразу)
  iof relay add узел через    например: iof relay add france netherlands
  iof relay del узел через    убрать ретранслятор
  iof relay list              ретрансляторы и их состояние
  iof relay apply             заново применить правила

Безопасность (run, show и cron на узлах ничего не меняют)
  iof audit run [блок]        проверить узлы. Блоки: server — SSH, файрвол, подбор паролей, обновления,
                              открытые порты; dpi — чем узел заметен для фильтров и зондов: маскировка
                              Hysteria2 и AmneziaWG, что видно снаружи, репутация адреса; all — оба (по умолчанию)
  iof audit show [узел]       последняя проверка: все пункты, что не так и как исправить
  iof audit cron              для cron раз в сутки: проверка и сообщение в Telegram, если стало хуже

Блок-лист сканеров (список BLOCKLIST_URL, адреса узлов и этого сервера не блокируются)
  iof block on узлы           применить на узлах (all — на всех), переживает перезагрузку
  iof block update [узлы]     скачать список заново и обновить там, где он включён (для cron раз в сутки)
  iof block off узлы          снять целиком

Доступность из РФ, проверка с ПК (на узлах на время проверки работают мишени)
  iof audit probe start       мишени на узлах на PROBE_TTL секунд (900) и проверка до них отсюда;
                              --ttl секунд — свой срок. Скрипт для ПК даёт страница «Безопасность» панели
  iof audit probe stop        остановить мишени раньше срока
  iof audit probe import < отчёт.json   принять отчёт скрипта с ПК, если он не дошёл до панели
  iof audit probe list        последняя проверка по слоям и прошлые проверки

Телеграм-бот (работает внутри веб-панели iof-web, отвечает только админам в личном чате)
  iof bot show                включён ли, бот, админы, неиспользованные приглашения
  iof bot token               токен от @BotFather: спросит или возьмёт со stdin; пустой — удалить и выключить
  iof bot on | off            включить или выключить бота
  iof bot set actions on|off  разрешить действия из бота (только главным админам)
  iof bot set links on|off    выдавать в боте ссылки Hysteria2
  iof bot set quiet 23:00-08:00|off   тихие часы уведомлений
  iof bot invite main|regular код приглашения админа (главный или обычный): один раз, 24 часа;
                              будущий админ отправляет его боту
  iof bot invite del хэш      отозвать приглашение
  iof bot admin set ID role main|regular   сменить роль админа
  iof bot admin set ID sound on|off        уведомления со звуком в тихие часы
  iof bot admin set ID notify nodes,audit  какие уведомления получает админ: типы через запятую, all или off
  iof bot admin del ID        удалить админа

Перенос управляющего сервера (этот остаётся VPN-узлом, клиенты ничего не заметят)
  iof migrate start хост [порт]   на старом: поставить iof на новый сервер и скопировать туда данные
      --user, --key, --key-installed  вход как у node add
      --self root@адрес[:порт]    как новый сервер будет заходить сюда (по умолчанию адрес узла local)
  iof migrate finish          на новом: снять управление со старого (--skip-old, если тот недоступен)
  iof migrate cancel          на старом: отменить перенос
  iof migrate status          идёт ли перенос

Выбор узлов: -n перед командой ограничивает status, check, exec, hy2 status, awg status, awg clients, audit, block update
  iof -n 'de-*' status
  iof -n de-1,de-2 exec "apt update"
Сколько узлов одновременно: PARALLEL в /root/iof/iof.env (по умолчанию 20)
EOF
}


# Точка входа

[[ $EUID -eq 0 ]] || die "запусти от root: sudo iof ..."

while [[ "${1:-}" == "-n" ]]; do
  IOF_ONLY="${2:-}"
  [[ -n "$IOF_ONLY" ]] || die "после -n укажи узлы, например: iof -n 'de-*' status"
  shift 2
done

cmd="${1:-}"
if [[ $# -gt 0 ]]; then shift; fi

# Пока идёт перенос отсюда, команды, которые что-то меняют, запрещены
case "$cmd:${1:-}" in
  setup:*|init:*|refresh:*|node:add|node:import|node:del|node:rename|relay:add|relay:del|relay:apply) migrate_guard ;;
  hy2:add|hy2:del|hy2:refresh|hy2:install|hy2:hop|hy2:upgrade|awg:install|awg:add|awg:del|awg:refresh) migrate_guard ;;
  block:on|block:update|block:off) migrate_guard ;;
  bot:token|bot:on|bot:off|bot:set|bot:invite|bot:redeem|bot:admin) migrate_guard ;;
esac
# Мишени проверки с ПК меняют узлы, а import пишет результат сюда, а не на новый сервер
case "$cmd:${1:-}:${2:-}" in
  audit:probe:start|audit:probe:stop|audit:probe:import) migrate_guard ;;
esac

case "$cmd" in
  hy2)     cmd_hy2 "$@" ;;
  awg)     cmd_awg "$@" ;;
  vless)   cmd_vless "$@" ;;
  node)    cmd_node "$@" ;;
  relay)   cmd_relay "$@" ;;
  block)   cmd_block "$@" ;;
  migrate) cmd_migrate "$@" ;;
  audit)   cmd_audit "$@" ;;
  bot)     cmd_bot "$@" ;;
  status)  cmd_status ;;
  check)   cmd_check "$@" ;;
  notify)  cmd_notify "$@" ;;
  exec)    cmd_exec "$@" ;;
  refresh) cmd_refresh ;;
  api)     cmd_api "$@" ;;
  update)  cmd_update "$@" ;;
  version) echo "iof $IOF_VERSION" ;;
  setup)   cmd_setup "$@" ;;
  init)    cmd_init ;;
  *)       usage ;;
esac
