#!/usr/bin/env bash

# Статические проверки репозитория: синтаксис, shellcheck, pyflakes и правила проекта из CLAUDE.md,
# которые легко забыть (NODE_FUNCS, STATIC_FILES, CSP панели, probe.ps1, переводы строк LF).
# CI запускает её на каждый push, локально: bash ci/lint.sh (Linux, WSL или Git Bash).
# Если shellcheck, python3 или pyflakes не установлены, их проверки пропускаются, а в CI это ошибка.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
SHELL_FILES=(iof.sh iof-nightly install.sh stand/stand.sh stand/test.sh ci/lint.sh)
# Панель, модуль Telegram-бота и поддельный Bot API стенда
PY_FILES=(web/iof-web.py web/iof_bot.py stand/fake-tg.py)
# Сторонний код в web/static: xterm.js для терминала на странице узла. Правила CSP к нему не применяются:
# свои <style> он создаёт скриптом, и term.js переносит их в adoptedStyleSheets. Файлы берутся из npm
# целиком, первая строка называет пакет и версию (CLAUDE.md, «Веб-панель»)
VENDOR=(web/static/xterm.js web/static/xterm-fit.js web/static/xterm.css)
FAILED=0

ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; FAILED=$((FAILED + 1)); }
# Найденное с отступом под строкой FAIL
details() { sed 's/^/      /' <<<"$1"; }
# Список по строке -> в одну строку через пробел
words() { tr '\n' ' ' <<<"$1"; }
# Нет инструмента: локально проверка пропускается, в CI (там CI=true) это ошибка
missing() {
  if [[ -n "${CI:-}" ]]; then fail "$1: не установлен"; else echo "skip  $1: не установлен"; fi
}
# Строки grep вида файл:номер:текст без комментариев js и css: в них правила можно упоминать
code_only() { grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/?\*)'; }
# Аргументы, кроме стороннего кода из VENDOR, по строке
own_files() {
  local f v
  for f in "$@"; do
    for v in "${VENDOR[@]}"; do
      if [[ "$f" == "$v" ]]; then continue 2; fi
    done
    echo "$f"
  done
}

check_bash() {
  local f out
  for f in "${SHELL_FILES[@]}"; do
    if out="$(bash -n "$f" 2>&1)"; then ok "bash -n $f"; else fail "bash -n $f"; details "$out"; fi
  done
}

# Настройки в .shellcheckrc
check_shellcheck() {
  local out
  if ! command -v shellcheck >/dev/null 2>&1; then missing shellcheck; return; fi
  if out="$(shellcheck --severity=warning "${SHELL_FILES[@]}" 2>&1)"; then
    ok "shellcheck $(shellcheck --version | sed -n 's/^version: //p')"
  else
    fail "shellcheck"
    details "$out"
  fi
}

# Тот же разбор, что делает install.sh перед установкой, и pyflakes: неопределённые имена,
# лишние импорты. На машине разработки python3 бывает заглушкой Microsoft Store, она не запустится
check_python() {
  local out f
  if ! python3 -c '' >/dev/null 2>&1; then missing python3; return; fi
  for f in "${PY_FILES[@]}"; do
    if out="$(python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$f" 2>&1)"; then
      ok "python3: $f разбирается"
    else
      fail "python3: $f"
      details "$out"
    fi
  done
  # В CI pyflakes ставится через pipx и есть только командой, в Ubuntu (apt install pyflakes3) — модулем
  local pf=(pyflakes)
  if ! command -v pyflakes >/dev/null 2>&1; then
    pf=(python3 -m pyflakes)
    if ! "${pf[@]}" --version >/dev/null 2>&1; then missing pyflakes; return; fi
  fi
  for f in "${PY_FILES[@]}"; do
    if out="$("${pf[@]}" "$f" 2>&1)"; then ok "pyflakes $f"; else fail "pyflakes $f"; details "$out"; fi
  done
}

check_js() {
  local f out
  if ! command -v node >/dev/null 2>&1; then missing node; return; fi
  for f in web/static/*.js; do
    if out="$(node --check "$f" 2>&1)"; then ok "node --check $f"; else fail "node --check $f"; details "$out"; fi
  done
}

# run_on отправляет на узел только функции из NODE_FUNCS: новая n_* без записи там на узле не найдётся
check_node_funcs() {
  local defined listed extra lost
  defined="$(grep -oE '^n_[A-Za-z0-9_]+\(\)' iof.sh | tr -d '()' | sort -u)"
  listed="$(sed -n '/^NODE_FUNCS=(/,/^)/p' iof.sh | sed '1d;$d' | tr -s ' \t' '\n' | grep -v '^$' | sort -u)"
  extra="$(comm -23 <(echo "$defined") <(echo "$listed"))"
  lost="$(comm -13 <(echo "$defined") <(echo "$listed"))"
  if [[ -z "$extra" && -z "$lost" ]]; then
    ok "NODE_FUNCS: все функции n_* ($(wc -l <<<"$defined"))"
  else
    fail "NODE_FUNCS не совпадает с функциями n_* в iof.sh"
    if [[ -n "$extra" ]]; then details "нет в NODE_FUNCS: $(words "$extra")"; fi
    if [[ -n "$lost" ]]; then details "в NODE_FUNCS, но не определены: $(words "$lost")"; fi
  fi
}

# Панель отдаёт статику только из словаря STATIC_FILES, install.sh ставит весь web/static
check_static() {
  local served present extra lost
  served="$(sed -n '/^STATIC_FILES = {/,/^}/p' web/iof-web.py | grep -oE ': \("[^"]+"' | sed -E 's/^: \("//; s/"$//' | sort -u)"
  present="$(cd web/static && ls | sort -u)"
  extra="$(comm -13 <(echo "$served") <(echo "$present"))"
  lost="$(comm -23 <(echo "$served") <(echo "$present"))"
  if [[ -z "$extra" && -z "$lost" ]]; then
    ok "STATIC_FILES: все файлы web/static ($(wc -l <<<"$present"))"
  else
    fail "STATIC_FILES не совпадает с web/static"
    if [[ -n "$extra" ]]; then details "нет в STATIC_FILES (панель их не отдаст): $(words "$extra")"; fi
    if [[ -n "$lost" ]]; then details "в STATIC_FILES, но нет в web/static: $(words "$lost")"; fi
  fi
}

# CSP панели default-src 'self': встроенные скрипты, атрибуты style= и on...=, javascript: и внешние
# адреса браузер не выполнит. Стили из кода — только через CSSOM (element.style.width)
check_csp() {
  local found html code all
  mapfile -t html < <(own_files web/static/*.html)
  mapfile -t code < <(own_files web/static/*.html web/static/*.js)
  mapfile -t all < <(own_files web/static/*)
  found="$(
    grep -nE '<script\b' "${html[@]}" | grep -v 'src='
    grep -nE '<style\b|[[:space:]]style=|setAttribute\(["'"'"']style|[[:space:]]on[a-z]+=["'"'"']|javascript:' \
      "${code[@]}" | code_only
    grep -nE '(src|href)=["'"'"']?(https?:)?//|url\(["'"'"']?(https?:)?//|@import' "${all[@]}" | code_only
  )"
  if [[ -z "$found" ]]; then
    ok "CSP: нет встроенных скриптов, style=, обработчиков on...= и внешних адресов"
  else
    fail "CSP: такое панель не выполнит (см. CLAUDE.md, «Веб-панель»)"
    details "$found"
  fi
}

# Боковое меню повторено в каждом html: пункты должны совпадать, отличается только отметка
# текущего пункта aria-current (page, а на странице узла true у «Обзора»)
check_menu() {
  local f ref cur bad=""
  ref="$(sed -n '/<nav class="nav"/,/<\/nav>/p' web/static/index.html | sed -E 's/ aria-current="[a-z]+"//')"
  for f in web/static/*.html; do
    cur="$(sed -n '/<nav class="nav"/,/<\/nav>/p' "$f")"
    if [[ "$(sed -E 's/ aria-current="[a-z]+"//' <<<"$cur")" != "$ref" ]]; then bad+="$f "; fi
    if [[ "$(grep -c 'aria-current=' <<<"$cur")" != "1" ]]; then bad+="$f(aria-current) "; fi
  done
  if [[ -z "$bad" ]]; then
    ok "меню: одинаковое во всех html ($(grep -c '<a href' <<<"$ref") пунктов)"
  else
    fail "меню отличается от index.html или текущий пункт не отмечен: $bad"
  fi
}

# Сторонний код на месте и с заголовком: какой пакет npm и какая версия
check_vendor() {
  local f head bad=""
  for f in "${VENDOR[@]}"; do
    head="$(head -n 1 "$f" 2>/dev/null)"
    if [[ "$head" != *"@xterm/"*" "[0-9]* ]]; then bad+="$f "; fi
  done
  if [[ -z "$bad" ]]; then
    ok "сторонний код: $(head -n 1 web/static/xterm.js | grep -oE '@xterm/[a-z-]+ [0-9.]+'), $(head -n 1 web/static/xterm-fit.js | grep -oE '@xterm/[a-z-]+ [0-9.]+')"
  else
    fail "сторонний код: нет файла или первой строки с пакетом и версией: $bad"
  fi
}

# Скрипт проверки с ПК: на месте, только ASCII (Windows PowerShell 5.1 читает файл без BOM в кодировке
# ANSI), одна метка, куда панель вписывает данные проверки, и разбирается парсером PowerShell, если он
# есть: pwsh на раннерах GitHub, powershell.exe в Windows. Без PowerShell разбор пропускается
check_probe() {
  local f="web/probe.ps1" n ps path out
  if [[ ! -f "$f" ]]; then fail "probe.ps1: нет $f, его отдаёт панель для проверки с ПК"; return; fi
  n="$(LC_ALL=C tr -d '\000-\177' < "$f" | wc -c)"
  if (( n == 0 )); then ok "probe.ps1: только ASCII"; else fail "probe.ps1: не ASCII байт: $n"; fi
  n="$(grep -c '__IOF_PROBE_CONFIG__' "$f")"
  if [[ "$n" == "1" ]]; then ok "probe.ps1: одна метка для данных проверки"; else fail "probe.ps1: метка __IOF_PROBE_CONFIG__ должна быть одна, а их $n"; fi
  if command -v pwsh >/dev/null 2>&1; then
    ps=pwsh
    path="$ROOT/$f"
    # PowerShell 7 в Git Bash тоже Windows-программа: путь внутри -Command MSYS не переводит
    if command -v cygpath >/dev/null 2>&1; then path="$(cygpath -w "$path")"; fi
  elif command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    ps=powershell.exe
    path="$(cygpath -w "$ROOT/$f")"
  else
    echo "skip  probe.ps1: нет PowerShell для разбора"
    return
  fi
  local script="\$t = \$null; \$e = \$null; [void][Management.Automation.Language.Parser]::ParseFile('$path', [ref]\$t, [ref]\$e);"
  script+=" \$e | ForEach-Object { [string]\$_.Extent.StartLineNumber + ': ' + \$_.Message }; exit [int](\$e.Count -gt 0)"
  if out="$("$ps" -NoProfile -NonInteractive -Command "$script" 2>&1)"; then
    ok "probe.ps1: разбирается ($ps)"
  else
    fail "probe.ps1: ошибки разбора ($ps)"
    details "$out"
  fi
}

# Типы уведомлений записаны в четырёх местах: NOTIFY_KINDS и NOTIFY в BOT_PY (iof.sh), BOT_NOTIFY (панель)
# и NOTIFY (страница «Телеграм бот»). Новый тип, добавленный не везде, iof не отправит или страница не покажет
check_notify() {
  local sh py web js
  sh="$(sed -n 's/^NOTIFY_KINDS="\(.*\)"$/\1/p' iof.sh)"
  py="$(sed -n '/^NOTIFY = {/,/^}/p' iof.sh | grep -oE '^    "[a-z]+"' | tr -d ' "' | tr '\n' ' ' | sed 's/ $//')"
  web="$(grep -E '^BOT_NOTIFY = \(' web/iof-web.py | grep -oE '"[a-z]+"' | tr -d '"' | tr '\n' ' ' | sed 's/ $//')"
  js="$(sed -n '/^const NOTIFY = \[/,/^\];/p' web/static/bot.js | grep -oE '^  \["[a-z]+"' | tr -d ' ["' | tr '\n' ' ' | sed 's/ $//')"
  if [[ -n "$sh" && "$sh" == "$py" && "$sh" == "$web" && "$sh" == "$js" ]]; then
    ok "типы уведомлений одинаковы в iof.sh, iof-web.py и bot.js: $sh"
  else
    fail "типы уведомлений расходятся"
    details "NOTIFY_KINDS: $sh"$'\n'"NOTIFY (BOT_PY): $py"$'\n'"BOT_NOTIFY: $web"$'\n'"NOTIFY (bot.js): $js"
  fi
}

# Скрипты запускаются на Linux: в репозитории только LF (.gitattributes)
check_eol() {
  local found
  if ! git rev-parse --git-dir >/dev/null 2>&1; then missing git; return; fi
  found="$(git ls-files --eol | awk '$1 ~ /crlf/ {print $NF}')"
  if [[ -z "$found" ]]; then ok "переводы строк: только LF"; else fail "файлы с CRLF в репозитории"; details "$found"; fi
}

check_bash
check_shellcheck
check_python
check_js
check_node_funcs
check_static
check_csp
check_menu
check_vendor
check_probe
check_notify
check_eol

echo
if (( FAILED == 0 )); then
  echo "Все проверки пройдены"
else
  echo "Не пройдено проверок: $FAILED"
  exit 1
fi
