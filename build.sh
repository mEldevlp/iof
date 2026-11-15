#!/usr/bin/env bash

# Собирает автономный iof в stdout: bash build.sh > /tmp/iof.
# Порядок модулей берётся из source в iof.sh, второго списка для установки нет.
# При ошибке синтаксиса или неполном списке модулей stdout остаётся пустым.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
die() { echo "Ошибка сборки: $*" >&2; exit 1; }

for f in "$ROOT/iof.sh" "$ROOT"/lib/*.sh; do
  bash -n "$f" || die "$f не проходит bash -n"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
declare -A INCLUDED=()
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    'IOF_LIB='*|'unset IOF_LIB'|'# shellcheck source=lib/'*) ;;
    'source "$IOF_LIB/'*)
      module="${line#'source "$IOF_LIB/'}"
      module="${module%\"}"
      [[ "$module" =~ ^[a-z_][a-z0-9_]*\.sh$ ]] || die "неверное подключение: $line"
      [[ -z "${INCLUDED[$module]:-}" ]] || die "модуль lib/$module подключён дважды"
      INCLUDED[$module]=1
      printf '# Модуль lib/%s\n' "$module"
      cat "$ROOT/lib/$module" || die "не удалось прочитать lib/$module"
      printf '\n' ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$ROOT/iof.sh" > "$TMP/iof"

for f in "$ROOT"/lib/*.sh; do
  [[ -n "${INCLUDED[${f##*/}]:-}" ]] || die "модуль lib/${f##*/} не подключён в iof.sh"
done
bash -n "$TMP/iof" || die "собранный iof не проходит bash -n"
cat "$TMP/iof"
