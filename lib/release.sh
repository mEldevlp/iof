#!/usr/bin/env bash

# Версия клона для установщика и страницы «Сервис».
source_version() {
  local src="$1" tag version
  version="$(git -C "$src" log -1 --format='%h %cd' --date=short 2>/dev/null)" || return 1
  tag="$(git -C "$src" tag --points-at HEAD --sort=-version:refname \
    | awk '/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ && !found { print; found=1 }')"
  if [[ -n "$tag" ]]; then version="$tag ${version#* }"; fi
  if ! git -C "$src" diff --quiet HEAD --; then version+=" с правками"; fi
  printf '%s\n' "$version"
}

# Проверяем опубликованный стабильный релиз того же GitHub-репозитория, откуда берётся его тег.
release_tag() {
  local url="${IOF_RELEASE_API:-}" origin repo
  if [[ -z "$url" ]]; then
    origin="$(git -C "$IOF_SRC" remote get-url origin)" || die "у клона нет удалённого репозитория origin"
    origin="${origin%/}"
    origin="${origin%.git}"
    case "$origin" in
      https://github.com/*) repo="${origin#https://github.com/}" ;;
      git@github.com:*) repo="${origin#git@github.com:}" ;;
      ssh://git@github.com/*) repo="${origin#ssh://git@github.com/}" ;;
      *) die "для релизов origin должен указывать на публичный репозиторий GitHub" ;;
    esac
    [[ "$repo" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+$ ]] || die "неверный адрес GitHub в origin"
    url="https://api.github.com/repos/$repo/releases/latest"
  fi
  have python3 || die "для проверки релизов нужен python3: apt install python3"
  timeout 20 python3 - "$url" <<'PY'
import json
import re
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

try:
    req = Request(sys.argv[1], headers={"Accept": "application/vnd.github+json", "User-Agent": "iof"})
    with urlopen(req, timeout=12) as response:
        release = json.load(response)
except HTTPError as exc:
    if exc.code == 404:
        sys.exit(0)
    sys.exit(f"Ошибка: GitHub вернул HTTP {exc.code} при проверке релиза")
except (OSError, ValueError):
    sys.exit("Ошибка: не удалось получить сведения о релизе GitHub")

if not isinstance(release, dict):
    sys.exit("Ошибка: неверный ответ GitHub о релизе")
if release.get("draft") is not False or release.get("prerelease") is not False or not release.get("published_at"):
    sys.exit(0)
tag = release.get("tag_name")
if not isinstance(tag, str) or not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
    sys.exit("Ошибка: метка стабильного релиза должна иметь формат vN.N")
print(tag)
PY
}

# В FETCH_HEAD могут одновременно писать другие проверки. Скачиваем в конкретный тег без замены чужого тега.
release_info() {
  REL_AVAILABLE=no
  REL_COMMIT=""
  REL_INSTALLED=""
  REL_TAG="$(release_tag)" || die "не удалось проверить опубликованный релиз"
  [[ -n "$REL_TAG" ]] || return 0
  local ref="refs/tags/$REL_TAG" version="${IOF_VERSION%% *}"
  GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$IOF_SRC" fetch --quiet --no-tags --no-write-fetch-head origin "$ref:$ref" \
    || die "не удалось получить тег $REL_TAG из origin"
  REL_COMMIT="$(git -C "$IOF_SRC" rev-parse --verify "$ref^{commit}")" || die "тег $REL_TAG не указывает на коммит"
  REL_INSTALLED="$(git -C "$IOF_SRC" rev-parse --verify "${IOF_REVISION:-$version}^{commit}" 2>/dev/null)" || REL_INSTALLED=""
  if [[ "$REL_INSTALLED" == "$REL_COMMIT" && "$version" == "$REL_TAG" ]]; then
    return 0
  fi
  if [[ -n "$REL_INSTALLED" && "$REL_INSTALLED" != "$REL_COMMIT" ]]; then
    if git -C "$IOF_SRC" merge-base --is-ancestor "$REL_COMMIT" "$REL_INSTALLED"; then return 0; fi
    git -C "$IOF_SRC" merge-base --is-ancestor "$REL_INSTALLED" "$REL_COMMIT" \
      || die "история релиза $REL_TAG разошлась с установленной версией"
  fi
  REL_AVAILABLE=yes
}

update_release() {
  release_info
  if [[ -z "$REL_TAG" ]]; then
    echo "Опубликованных релизов пока нет"
    return 0
  fi
  if [[ "$REL_AVAILABLE" == no && "$REL_INSTALLED" != "$REL_COMMIT" ]]; then
    echo "Установленная версия новее релиза $REL_TAG"
    return 0
  fi
  [[ -z "$(git -C "$IOF_SRC" status --porcelain --untracked-files=all)" ]] \
    || die "в клоне $IOF_SRC есть локальные изменения, сохрани их перед установкой релиза"
  git -C "$IOF_SRC" checkout --quiet --detach --no-overwrite-ignore "$REL_COMMIT" \
    || die "не удалось открыть релиз $REL_TAG в $IOF_SRC"
  echo "Устанавливаю опубликованный релиз $REL_TAG"
  exec bash "$IOF_SRC/install.sh" "$@"
}
