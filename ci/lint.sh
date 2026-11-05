#!/usr/bin/env bash

# Статические проверки репозитория: синтаксис, shellcheck, pyflakes и правила проекта из CLAUDE.md,
# которые легко забыть (NODE_FUNCS, STATIC_FILES, CSP панели, переводы строк LF).
# CI запускает её на каждый push, локально: bash ci/lint.sh (Linux, WSL или Git Bash).
# Если shellcheck, python3 или pyflakes не установлены, их проверки пропускаются, а в CI это ошибка.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
SHELL_FILES=(iof.sh iof-nightly install.sh stand/stand.sh stand/test.sh ci/lint.sh)
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
  local out
  if ! python3 -c '' >/dev/null 2>&1; then missing python3; return; fi
  if out="$(python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' web/iof-web.py 2>&1)"; then
    ok "python3: web/iof-web.py разбирается"
  else
    fail "python3: web/iof-web.py"
    details "$out"
  fi
  # В CI pyflakes ставится через pipx и есть только командой, в Ubuntu (apt install pyflakes3) — модулем
  local pf=(pyflakes)
  if ! command -v pyflakes >/dev/null 2>&1; then
    pf=(python3 -m pyflakes)
    if ! "${pf[@]}" --version >/dev/null 2>&1; then missing pyflakes; return; fi
  fi
  if out="$("${pf[@]}" web/iof-web.py 2>&1)"; then ok "pyflakes web/iof-web.py"; else fail "pyflakes web/iof-web.py"; details "$out"; fi
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
check_vendor
check_eol

echo
if (( FAILED == 0 )); then
  echo "Все проверки пройдены"
else
  echo "Не пройдено проверок: $FAILED"
  exit 1
fi
