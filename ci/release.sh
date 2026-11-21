#!/usr/bin/env bash

# Публикует предварительные выпуски и осознанно переводит проверенный выпуск в стабильный.
# Номер резервируется созданием тега на origin без force, поэтому параллельные задачи не делят версию.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Использование: ci/release.sh prerelease <SHA> | promote <тег> <SHA>
EOF
  exit 2
}

die() { echo "Ошибка публикации: $*" >&2; exit 1; }

[[ $# -ge 2 ]] || usage
mode="$1"
repo="${GITHUB_REPOSITORY:?Не задан GITHUB_REPOSITORY}"

# Возвращает строку GitHub Releases: тег, draft, prerelease.
release_row() {
  gh api "repos/$repo/releases/tags/$1" \
    --jq 'select(.published_at != null) | [.tag_name, (.draft | tostring), (.prerelease | tostring)] | @tsv'
}

numeric_tag() { [[ "$1" =~ ^v0\.(0|[1-9][0-9]*)$ ]]; }

# Находит уже зарезервированный числовой тег этого коммита. Для аннотированных тегов берёт peeled ref.
tag_for_commit() {
  local expected="$1" object ref name tag refs
  refs="$(git ls-remote --tags origin)" || die "не удалось получить теги origin"
  declare -A direct=() peeled=()
  while read -r object ref; do
    [[ -n "$object" && -n "$ref" ]] || continue
    name="${ref#refs/tags/}"
    if [[ "$name" == *'^{}' ]]; then
      peeled["${name%^\{\}}"]="$object"
    else
      direct["$name"]="$object"
    fi
  done <<< "$refs"
  for tag in "${!direct[@]}"; do
    numeric_tag "$tag" || continue
    object="${peeled[$tag]:-${direct[$tag]}}"
    if [[ "$object" == "$expected" ]]; then printf '%s\n' "$tag"; fi
  done | sort -V | head -n 1
}

# Номер берётся из всех удалённых числовых тегов и всех типов Releases, включая draft/prerelease.
next_tag() {
  local object ref name tag max=8 n refs releases
  refs="$(git ls-remote --tags origin)" || die "не удалось получить теги origin"
  releases="$(gh api --paginate "repos/$repo/releases" --jq '.[].tag_name')" || die "не удалось получить список релизов"
  while read -r object ref; do
    name="${ref#refs/tags/}"
    [[ "$name" == *'^{}' ]] && continue
    numeric_tag "$name" || continue
    n="${name#v0.}"
    (( 10#$n > max )) && max=$((10#$n))
  done <<< "$refs"
  while IFS= read -r tag; do
    numeric_tag "$tag" || continue
    n="${tag#v0.}"
    (( 10#$n > max )) && max=$((10#$n))
  done <<< "$releases"
  printf 'v0.%d\n' "$((max + 1))"
}

# Создаёт удалённый lightweight-тег только при отсутствии ссылки. При конфликте пересчитывает номер.
reserve_tag() {
  local sha="$1" tag attempt=0
  while (( attempt++ < 100 )); do
    tag="$(tag_for_commit "$sha")" || return 1
    if [[ -n "$tag" ]]; then
      printf '%s\n' "$tag"
      return
    fi
    tag="$(next_tag)" || return 1
    if git push origin "$sha:refs/tags/$tag"; then
      printf '%s\n' "$tag"
      return
    fi
    echo "Тег $tag уже успела занять другая публикация, выбираю следующий" >&2
  done
  die "не удалось зарезервировать номер после 100 попыток"
}

release_notes() {
  local sha="$1" file="$2" kind="${3:-Предварительный}"
  {
    printf '%s выпуск Island of Freedom для коммита `%s`.\n\n' "$kind" "$sha"
    git log -n 8 --format='- %s (`%h`)' "$sha"
  } > "$file"
}

publish_prerelease() {
  local sha="$1" tag row got draft prerelease notes
  tag="$(reserve_tag "$sha")"
  if row="$(release_row "$tag" 2>/dev/null)"; then
    IFS=$'\t' read -r got draft prerelease <<<"$row"
    [[ "$got" == "$tag" ]] || die "API вернул другой тег вместо $tag"
    [[ "$(tag_for_commit "$sha")" == "$tag" ]] || die "тег $tag указывает не на проверенный коммит"
    [[ "$draft" == false ]] || die "релиз $tag является черновиком"
    if [[ "$prerelease" == true ]]; then
      echo "Предварительный релиз $tag для $sha уже опубликован"
      return
    fi
    echo "Стабильный релиз $tag для $sha уже опубликован"
    return
  fi

  notes="$(mktemp)"
  trap 'rm -f "$notes"' RETURN
  release_notes "$sha" "$notes"
  if ! gh release create "$tag" --repo "$repo" --target "$sha" --verify-tag --prerelease \
      --latest=false --title "$tag" --notes-file "$notes"; then
    # Параллельная задача либо повтор после обрыва могла создать Release между проверкой и create.
    row="$(release_row "$tag" 2>/dev/null)" || die "не удалось создать предварительный релиз $tag"
    IFS=$'\t' read -r got draft prerelease <<<"$row"
    [[ "$got" == "$tag" ]] && [[ "$(tag_for_commit "$sha")" == "$tag" ]] && [[ "$draft" == false && "$prerelease" == true ]] \
      || die "релиз $tag после конфликта не соответствует ожидаемому коммиту"
  fi
  echo "Опубликован предварительный релиз $tag для $sha"
}

promote() {
  local tag="$1" sha="$2" row got draft prerelease tag_sha
  numeric_tag "$tag" || die "нужен числовой тег формата v0.N"
  git fetch --quiet --no-tags origin "refs/tags/$tag:refs/tags/$tag"
  tag_sha="$(git rev-parse "refs/tags/$tag^{commit}" 2>/dev/null)" \
    || die "тег $tag отсутствует на origin"
  [[ "$tag_sha" == "$sha" ]] || die "тег $tag указывает не на проверенный коммит $sha"
  row="$(release_row "$tag" 2>/dev/null)" || die "для $tag нет предварительного релиза"
  IFS=$'\t' read -r got draft prerelease <<<"$row"
  [[ "$got" == "$tag" ]] || die "API вернул другой тег вместо $tag"
  [[ "$draft" == false ]] || die "черновик $tag нельзя повысить до стабильного"
  [[ "$prerelease" == true || "$prerelease" == false ]] || die "некорректный ответ GitHub для $tag"
  # --latest задаётся и при повторе: GitHub не должен выбирать стабильный выпуск неявно.
  gh release edit "$tag" --repo "$repo" --prerelease=false --latest --title "$tag"
  echo "Релиз $tag для $sha отмечен стабильным и последним"
}

case "$mode" in
  prerelease)
    [[ $# == 2 ]] || usage
    sha="$(git rev-parse --verify --end-of-options "$2^{commit}" 2>/dev/null)" || die "неизвестный коммит $2"
    publish_prerelease "$sha"
    ;;
  promote)
    [[ $# == 3 ]] || usage
    sha="$(git rev-parse --verify --end-of-options "$3^{commit}" 2>/dev/null)" || die "неизвестный коммит $3"
    promote "$2" "$sha"
    ;;
  *) usage ;;
esac
