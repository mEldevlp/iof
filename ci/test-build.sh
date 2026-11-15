#!/usr/bin/env bash

# Регрессии сборки: автономность, одинаковые функции и встроенные программы,
# отказ без частичного вывода при потерянном, лишнем, повторном или сломанном модуле.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/исходники с пробелами"
mkdir -p "$SRC"
cp "$ROOT/iof.sh" "$ROOT/build.sh" "$SRC/"
cp -R "$ROOT/lib" "$SRC/lib"

die() { echo "Ошибка проверки сборки: $*" >&2; exit 1; }

# Определения загружаются без точки входа: root и данные узлов для проверки не нужны.
# Путь к lib передаётся явно, потому что сокращённый исходник читается из /dev/fd.
snapshot() {
  IOF_TEST_LIB="$SRC/lib" bash -s -- "$1" <<'BASH'
set -euo pipefail
IOF_LIB="$IOF_TEST_LIB"
# shellcheck source=/dev/null
source <(sed -e '/^# Точка входа/,$d' -e '/^IOF_LIB=/d' "$1")
declare -f
declare -p NODE_FUNCS TABLE_PY AUDIT_NET_PY AUDIT_PY BOT_PY
BASH
}

# Вызов из другого каталога и путь с пробелами не должны влиять на сборку.
(cd "$TMP" && bash "$SRC/build.sh") > "$TMP/iof"
snapshot "$SRC/iof.sh" > "$TMP/source.snapshot"
mv "$SRC/lib" "$TMP/lib"
snapshot "$TMP/iof" > "$TMP/built.snapshot"
cmp -s "$TMP/source.snapshot" "$TMP/built.snapshot" || die "определения исходников и автономного iof различаются"
mv "$TMP/lib" "$SRC/lib"

reject() {
  local reason="$1"
  if bash "$SRC/build.sh" > "$TMP/output" 2> "$TMP/error"; then die "$reason: сборка прошла"; fi
  [[ ! -s "$TMP/output" && -s "$TMP/error" ]] || die "$reason: ожидались пустой stdout и причина в stderr"
}

mv "$SRC/lib/common.sh" "$TMP/common.sh"
reject "нет модуля"
cp "$TMP/common.sh" "$SRC/lib/common.sh"
printf '\nif\n' >> "$SRC/lib/common.sh"
reject "ошибка синтаксиса модуля"
cp "$TMP/common.sh" "$SRC/lib/common.sh"
cp "$TMP/common.sh" "$SRC/lib/extra.sh"
reject "лишний модуль"
rm "$SRC/lib/extra.sh"
printf '\nsource "$IOF_LIB/common.sh"\n' >> "$SRC/iof.sh"
reject "повтор модуля"
cp "$ROOT/iof.sh" "$SRC/iof.sh"
printf '\nif\n' >> "$SRC/iof.sh"
reject "ошибка синтаксиса точки входа"
echo "Автономная сборка и отказы при ошибках проверены"
