#!/usr/bin/env bash

# Версия клона для установщика и страницы «Сервис».
source_version() {
  local src="$1" tag version
  version="$(git -C "$src" log -1 --format='%h %cd' --date=short 2>/dev/null)" || return 1
  tag="${IOF_INSTALL_TAG:-}"
  if [[ -z "$tag" ]]; then
    tag="$(git -C "$src" tag --points-at HEAD --sort=-version:refname \
      | awk '/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ && !found { print; found=1 }')"
  fi
  if [[ -n "$tag" ]]; then version="$tag ${version#* }"; fi
  if ! git -C "$src" diff --quiet HEAD --; then version+=" с правками"; fi
  printf '%s\n' "$version"
}

# Один снимок публикаций для обоих каналов. Номер не заменяет порядок публикации и историю git.
release_catalog() {
  local url="${IOF_RELEASE_API:-}" origin repo
  if [[ -z "$url" ]]; then
    origin="$(git -C "$IOF_SRC" remote get-url origin)" || die "у клона нет удалённого репозитория origin"
    origin="${origin%/}"; origin="${origin%.git}"
    case "$origin" in
      https://github.com/*) repo="${origin#https://github.com/}" ;;
      git@github.com:*) repo="${origin#git@github.com:}" ;;
      ssh://git@github.com/*) repo="${origin#ssh://git@github.com/}" ;;
      *) die "для релизов origin должен указывать на публичный репозиторий GitHub" ;;
    esac
    [[ "$repo" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+$ ]] || die "неверный адрес GitHub в origin"
    url="https://api.github.com/repos/$repo/releases"
  fi
  have python3 || die "для проверки релизов нужен python3: apt install python3"
  timeout 45 python3 - "$url" <<'PY'
import json
import re
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def get(url):
    req = Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "iof"})
    try:
        with urlopen(req, timeout=12) as response:
            return json.load(response), response.headers.get("Link", "")
    except HTTPError as exc:
        if exc.code == 404:
            return None, ""
        raise


try:
    url = sys.argv[1]
    data, link = get(url if url.startswith("file:") else url + "?per_page=100")
    latest = None
    if isinstance(data, dict) and "releases" in data:
        latest, releases = data.get("latest"), data["releases"]
    elif isinstance(data, dict):  # Совместимость со старой стендовой подменой /latest.
        releases = [data]
    elif data is None:
        releases = []
    else:
        releases = data
    if not isinstance(releases, list):
        raise ValueError()
    pages = 0
    while link:
        match = re.search(r'<([^>]+)>; rel="next"', link)
        if not match:
            break
        next_url = match[1]
        # Не отправляем запрос по произвольному адресу из ответа.
        if not next_url.startswith(url + "?") or pages >= 100:
            raise ValueError()
        page, link = get(next_url)
        if not isinstance(page, list):
            raise ValueError()
        releases.extend(page)
        pages += 1
    valid = []
    for item in releases:
        if not isinstance(item, dict):
            raise ValueError()
        tag = item.get("tag_name", "")
        if (item.get("draft") is False and isinstance(item.get("prerelease"), bool)
                and item.get("published_at") and isinstance(tag, str)
                and re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)):
            valid.append(item)
    if not url.startswith("file:"):
        stable, _ = get(url + "/latest")
        latest = stable.get("tag_name") if isinstance(stable, dict) else None
    valid.sort(key=lambda r: (r["published_at"], r.get("id", 0)), reverse=True)
    for channel, pre in (("stable", False), ("test", True)):
        items = [r for r in valid if r["prerelease"] is pre]
        chosen = next((r for r in items if r["tag_name"] == latest), None) if not pre else None
        if chosen is None and items:
            chosen = items[0]
        print(channel + "\t" + (chosen["tag_name"] if chosen else ""))
    for item in valid:
        print("published\t" + item["tag_name"] + "\t" + ("test" if item["prerelease"] else "stable"))
except (OSError, ValueError, TypeError, KeyError):
    sys.exit("Ошибка: не удалось получить сведения о опубликованных релизах GitHub")
PY
}

# Старое имя используется стабильными уведомлениями и внешними сценариями.
release_tag() {
  release_catalog | awk -F '\t' '$1 == "stable" {print $2}'
}

# В FETCH_HEAD могут писать другие проверки. Получаем только неизменяемый тег без force.
release_info() {
  local channel="${1:-stable}" requested="${2:-}" kind tag published_channel version="${IOF_VERSION%% *}"
  REL_AVAILABLE=no REL_COMMIT="" REL_INSTALLED="" REL_TAG="" REL_STATE=missing REL_CHANNEL="$channel"
  [[ "$channel" == stable || "$channel" == test ]] || die "неизвестный канал обновления"
  if [[ -z "${REL_CATALOG+x}" ]]; then
    REL_CATALOG="$(release_catalog)" || die "не удалось проверить опубликованные релизы"
  fi
  if [[ -n "$requested" ]]; then
    [[ "$requested" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "неверный тег релиза"
    while IFS=$'\t' read -r kind tag published_channel; do
      if [[ "$kind" == published && "$tag" == "$requested" ]]; then
        # Пока админ подтверждал test, тот же тег мог стать стабильным.
        [[ "$published_channel" == "$channel" || "$channel:$published_channel" == test:stable ]] \
          || die "релиз $requested не принадлежит выбранному каналу"
        REL_TAG="$tag" REL_CHANNEL="$published_channel"
        break
      fi
    done <<< "$REL_CATALOG"
    [[ -n "$REL_TAG" ]] || die "релиз $requested не опубликован или является черновиком"
  else
    REL_TAG="$(awk -F '\t' -v c="$channel" '$1 == c { print $2; exit }' <<< "$REL_CATALOG")"
  fi
  [[ -n "$REL_TAG" ]] || return 0
  local ref="refs/tags/$REL_TAG"
  GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$IOF_SRC" fetch --quiet --no-tags --no-write-fetch-head origin "$ref:$ref" \
    || die "не удалось получить неизменённый тег $REL_TAG из origin"
  REL_COMMIT="$(git -C "$IOF_SRC" rev-parse --verify "$ref^{commit}")" || die "тег $REL_TAG не указывает на коммит"
  REL_INSTALLED="$(git -C "$IOF_SRC" rev-parse --verify "${IOF_REVISION:-$version}^{commit}" 2>/dev/null)" || REL_INSTALLED=""
  REL_STATE=update
  if [[ "$REL_INSTALLED" == "$REL_COMMIT" ]]; then REL_STATE=current; return 0; fi
  if [[ -n "$REL_INSTALLED" ]]; then
    if git -C "$IOF_SRC" merge-base --is-ancestor "$REL_COMMIT" "$REL_INSTALLED"; then REL_STATE=older; return 0; fi
    if ! git -C "$IOF_SRC" merge-base --is-ancestor "$REL_INSTALLED" "$REL_COMMIT"; then REL_STATE=diverged; return 0; fi
  fi
  REL_AVAILABLE=yes
}

update_release() {
  local channel="$1" tag="$2" downgrade="$3" expected="$4"
  shift 4
  release_info "$channel" "$tag"
  if [[ -z "$REL_TAG" ]]; then echo "Опубликованных релизов канала $channel пока нет"; return 0; fi
  [[ -z "$expected" || "$expected" == "$REL_COMMIT" ]] || die "коммит выбранного релиза изменился"
  [[ "$REL_STATE" != diverged ]] || die "история релиза $REL_TAG разошлась с установленной версией"
  if [[ "$REL_STATE" == older && "$downgrade" != 1 ]]; then
    if [[ -n "$tag" ]]; then die "релиз $REL_TAG старее установленного; нужен явный возврат на стабильную версию"; fi
    echo "Установленная версия новее релиза $REL_TAG"; return 0
  fi
  if [[ "$downgrade" == 1 ]]; then
    [[ "$channel" == stable && -n "$tag" && "$REL_CHANNEL" == stable ]] || die "возврат разрешён только на явно выбранный стабильный релиз"
  fi
  if [[ "$REL_STATE" == current ]]; then echo "Релиз $REL_TAG уже установлен; канал: $REL_CHANNEL. Переустановка не нужна"; return 0; fi
  [[ -z "$(git -C "$IOF_SRC" status --porcelain --untracked-files=all)" ]] \
    || die "в клоне $IOF_SRC есть локальные изменения, сохрани их перед установкой релиза"
  git -C "$IOF_SRC" checkout --quiet --detach --no-overwrite-ignore "$REL_COMMIT" \
    || die "не удалось открыть релиз $REL_TAG в $IOF_SRC"
  echo "Устанавливаю опубликованный релиз $REL_TAG (канал: $REL_CHANNEL)"
  export IOF_INSTALL_TAG="$REL_TAG"
  exec bash "$IOF_SRC/install.sh" "$@"
}
