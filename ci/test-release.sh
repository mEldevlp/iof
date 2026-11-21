#!/usr/bin/env bash

# Проверяет идемпотентность, резервирование версий и повышение предварительных выпусков без GitHub.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REMOTE="$TMP/origin.git"
WORK="$TMP/work"
FAKE="$TMP/fake"
STATE="$TMP/releases.tsv"
LOG="$TMP/gh.log"
mkdir -p "$FAKE"
: > "$STATE"
: > "$LOG"

fail() { echo "Ошибка проверки издателя: $*" >&2; exit 1; }

cat > "$FAKE/gh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
state="${GH_STATE:?}"
log="${GH_LOG:?}"
cmd="${1:-}"
shift || true

row() {
  local tag="$1" line got sha draft pre
  while IFS=$'\t' read -r got sha draft pre; do
    [[ "$got" == "$tag" ]] && { printf '%s\t%s\t%s\n' "$got" "$draft" "$pre"; return 0; }
  done < "$state"
  return 1
}

case "$cmd" in
  api)
    if [[ "${1:-}" == --paginate ]]; then
      shift
      endpoint="${1:-}"
      shift || true
      [[ "$endpoint" == */releases ]] || exit 2
      cut -f1 "$state"
      exit 0
    fi
    endpoint="${1:-}"
    tag="${endpoint##*/}"
    row "$tag"
    ;;
  release)
    sub="${1:-}"
    shift || true
    tag="${1:-}"
    shift || true
    case "$sub" in
      create)
        sha= pre=false latest=false
        while (($#)); do
          case "$1" in
            --target) sha="$2"; shift 2 ;;
            --prerelease) pre=true; shift ;;
            --latest|--latest=false|--verify-tag) latest="$1"; shift ;;
            --repo|--title|--notes-file) shift 2 ;;
            *) shift ;;
          esac
        done
        row "$tag" >/dev/null && exit 1
        printf '%s\t%s\tfalse\t%s\n' "$tag" "$sha" "$pre" >> "$state"
        printf 'create %s %s %s %s\n' "$tag" "$sha" "$pre" "$latest" >> "$log"
        ;;
      edit)
        latest=false
        while (($#)); do
          case "$1" in
            --latest) latest=true; shift ;;
            --prerelease=false) shift ;;
            --repo|--title) shift 2 ;;
            *) shift ;;
          esac
        done
        row "$tag" >/dev/null || exit 1
        awk -F '\t' -v OFS='\t' -v tag="$tag" '{ if ($1 == tag) $4="false"; print }' "$state" > "$state.new"
        mv "$state.new" "$state"
        printf 'edit %s %s\n' "$tag" "$latest" >> "$log"
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
BASH
chmod +x "$FAKE/gh"

run() {
  (cd "$WORK" && PATH="$FAKE:$PATH" GH_STATE="$STATE" GH_LOG="$LOG" \
    GITHUB_REPOSITORY=test/iof bash "$ROOT/ci/release.sh" "$@")
}
row() { awk -F $'\t' -v tag="$1" '$1 == tag { print; exit }' "$STATE"; }
tag_for() {
  local sha="$1"
  git -C "$WORK" ls-remote --tags origin | awk -v sha="$sha" '$1 == sha && $2 !~ /\^\{\}$/ { sub("refs/tags/", "", $2); print $2; exit }'
}

# Четыре разных коммита дают материал для повторов, гонки и повышения не последнего выпуска.
git init --bare -q "$REMOTE"
git init -q "$WORK"
git -C "$WORK" config user.email test@example.invalid
git -C "$WORK" config user.name test
git -C "$WORK" config core.autocrlf false
git -C "$WORK" remote add origin "$REMOTE"
for name in A B C D E; do
  printf '%s\n' "$name" > "$WORK/file"
  git -C "$WORK" add file
  git -C "$WORK" commit -qm "$name"
  printf -v "SHA_$name" '%s' "$(git -C "$WORK" rev-parse HEAD)"
done
git -C "$WORK" branch -M master
git -C "$WORK" push -q -u origin master

# Повтор того же запуска не создаёт номер и не дублирует Release.
run prerelease "$SHA_A"
[[ "$(row v0.9)" == $'v0.9\t'"$SHA_A"$'\tfalse\ttrue' ]] || fail "не создан v0.9"
run prerelease "$SHA_A"
[[ "$(grep -c '^v0.9' "$STATE")" == 1 ]] || fail "повтор создал второй релиз"

# Обрыв после push тега: второй запуск должен завершить только создание Release.
git -C "$WORK" push -q origin "$SHA_B:refs/tags/v0.10"
run prerelease "$SHA_B"
[[ "$(row v0.10)" == $'v0.10\t'"$SHA_B"$'\tfalse\ttrue' ]] || fail "не восстановлена частичная публикация"

# Два разных SHA одновременно спорят за v0.11 и один обязательно повторяет резервирование.
run prerelease "$SHA_C" > "$TMP/c.out" 2> "$TMP/c.err" &
pid_c=$!
run prerelease "$SHA_D" > "$TMP/d.out" 2> "$TMP/d.err" &
pid_d=$!
wait "$pid_c" && wait "$pid_d" || fail "гонка публикаций завершилась ошибкой"
tag_c="$(tag_for "$SHA_C")"
tag_d="$(tag_for "$SHA_D")"
[[ "$tag_c" =~ ^v0\.1[12]$ && "$tag_d" =~ ^v0\.1[12]$ && "$tag_c" != "$tag_d" ]] \
  || fail "разным SHA не выделены v0.11 и v0.12"

# Можно повысить именно выбранный старый prerelease, когда существует более новый.
if [[ "$tag_c" == v0.11 ]]; then
  old_tag="$tag_c"
  old_sha="$SHA_C"
  new_tag="$tag_d"
  other_sha="$SHA_D"
else
  old_tag="$tag_d"
  old_sha="$SHA_D"
  new_tag="$tag_c"
  other_sha="$SHA_C"
fi
run promote "$old_tag" "$old_sha"
[[ "$(row "$old_tag")" == *$'\tfalse\tfalse' ]] || fail "выбранный prerelease не повышен"
[[ "$(row "$new_tag")" == *$'\tfalse\ttrue' ]] || fail "повышен невыбранный более новый prerelease"
tail -n 1 "$LOG" | grep -Fqx "edit $old_tag true" || fail "повышение не отметило latest явно"
run promote "$old_tag" "$old_sha"
if run promote "$old_tag" "$other_sha"; then fail "принят неверный SHA для повышения"; fi

# Draft даже с подходящим тегом не переводится в стабильный.
git -C "$WORK" push -q origin "$SHA_E:refs/tags/v0.20"
printf 'v0.20\t%s\ttrue\ttrue\n' "$SHA_E" >> "$STATE"
if run promote v0.20 "$SHA_E"; then fail "черновик был повышен"; fi

echo "Издатель: повторы, гонка, частичная публикация и повышение проверены"
