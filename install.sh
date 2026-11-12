#!/usr/bin/env bash

# Установка и обновление iof и веб-панели iof-web из клона репозитория.
# Первый раз:  sudo git clone https://github.com/mEldevlp/iof /opt/iof && sudo bash /opt/iof/install.sh
# Дальше:      sudo iof update   (git pull + этот скрипт)
# --no-web     поставить только iof, панель не трогать
set -euo pipefail

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
WEB_DIR="/opt/iof-web"
UNIT="/etc/systemd/system/iof-web.service"

die() { echo "Ошибка: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "запусти от root: sudo bash $0"
WEB=1
if [[ "${1:-}" == "--no-web" ]]; then WEB=0; fi

# Сначала проверка синтаксиса, при ошибке рабочие iof и iof-nightly остаются как были
bash -n "$SRC/iof.sh" || die "iof.sh не проходит bash -n, ничего не менял"
bash -n "$SRC/iof-nightly" || die "iof-nightly не проходит bash -n, ничего не менял"
# Версия (коммит и дата) подставляется в iof: её показывают iof version и страница «Сервис» панели
VERSION="$(git -C "$SRC" log -1 --format='%h %cd' --date=short 2>/dev/null || echo 'без git')"
if [[ "$VERSION" != "без git" ]] && ! git -C "$SRC" diff --quiet HEAD -- 2>/dev/null; then
  VERSION="$VERSION с правками"
fi
TMP="$(mktemp)"
sed "s|^IOF_VERSION=.*|IOF_VERSION=\"$VERSION\"|" "$SRC/iof.sh" > "$TMP"
install -m 700 "$TMP" /usr/local/bin/iof
rm -f "$TMP"
echo "iof: /usr/local/bin/iof ($VERSION)"

# Ночное обслуживание. Расписание в crontab root не трогаем, только подсказываем
install -m 700 "$SRC/iof-nightly" /usr/local/sbin/iof-nightly
echo "iof-nightly: /usr/local/sbin/iof-nightly"
if ! crontab -l -u root 2>/dev/null | grep -q '/usr/local/sbin/iof-nightly'; then
  echo "  в cron не запланирован. Каждую ночь в 4:00: sudo crontab -e, строка: 0 4 * * * /usr/local/sbin/iof-nightly"
fi
# Аудит безопасности раз в сутки, после ночного обслуживания. Тоже только подсказка
if ! crontab -l -u root 2>/dev/null | grep -q 'iof audit cron'; then
  echo "iof audit: в cron не запланирован. Раз в сутки: sudo crontab -e, строка: 30 5 * * * /usr/local/bin/iof audit cron >/dev/null 2>&1"
fi

if (( ! WEB )); then exit 0; fi

command -v python3 >/dev/null 2>&1 || die "нет python3: sudo apt install python3"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$SRC/web/iof-web.py" \
  || die "web/iof-web.py с ошибкой, панель не обновлял"

install -d -m 755 "$WEB_DIR" "$WEB_DIR/static"
install -m 644 "$SRC/web/iof-web.py" "$WEB_DIR/iof-web.py"
# Статику заменяем целиком, чтобы не оставались удалённые из репозитория файлы
rm -f "$WEB_DIR"/static/*
install -m 644 "$SRC"/web/static/* "$WEB_DIR/static/"
# Скрипт проверки с ПК не статика: панель отдаёт его только по одноразовому билету, вписав данные проверки
install -m 644 "$SRC/web/probe.ps1" "$WEB_DIR/probe.ps1"
install -m 644 "$SRC/web/iof-web.service" "$UNIT"
systemctl daemon-reload

if systemctl is-enabled --quiet iof-web 2>/dev/null; then
  systemctl restart iof-web
else
  systemctl enable --now iof-web
fi
sleep 1
if systemctl is-active --quiet iof-web; then
  echo "iof-web: работает, http://127.0.0.1:8088/ (с компьютера через SSH-туннель)"
else
  echo "iof-web: не запустился, смотри: journalctl -u iof-web -n 30" >&2
  exit 1
fi
if ! command -v qrencode >/dev/null 2>&1; then
  echo "Для QR-кодов на странице Hysteria2: sudo apt install qrencode"
fi
