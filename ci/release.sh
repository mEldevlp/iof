#!/usr/bin/env bash

# Публикация проверенной вершины master. Номер увеличивается как целое число: v0.9 → v0.10.
set -euo pipefail

commit="$(git rev-parse HEAD)"
previous="$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases" \
  --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
  | awk '/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/' | sort -V | tail -n 1)"
tag=v0.9
if [[ -n "$previous" ]]; then
  prior_commit="$(git rev-parse "refs/tags/$previous^{commit}")"
  if git merge-base --is-ancestor "$commit" "$prior_commit"; then
    echo "Этот коммит уже вошёл в $previous"
    exit 0
  fi
  git merge-base --is-ancestor "$prior_commit" "$commit" \
    || { echo "История master разошлась с релизом $previous" >&2; exit 1; }
  tag="${previous%.*}.$((10#${previous##*.} + 1))"
fi

verify=()
if git show-ref --verify --quiet "refs/tags/$tag"; then
  [[ "$(git rev-parse "refs/tags/$tag^{commit}")" == "$commit" ]] \
    || { echo "Тег $tag уже занят другим коммитом" >&2; exit 1; }
  verify=(--verify-tag)
fi

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
if [[ -n "$previous" ]]; then
  printf 'Изменения после %s\n\n' "$previous" > "$notes"
  git log --format='- %s (`%h`)' "$prior_commit..$commit" >> "$notes"
else
  printf 'Первый стабильный выпуск Island of Freedom.\n\n' > "$notes"
  git log -n 8 --format='- %s (`%h`)' "$commit" >> "$notes"
fi
gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$commit" "${verify[@]}" \
  --title "$tag" --notes-file "$notes" --latest
