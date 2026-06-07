#!/usr/bin/env bash

set -u

history_file="${1:-$HOME/.bash_history}"

patterns=(
    "apt-get install git"
    "dnf install git"
    "git clone"
    "./"
    "history -d"
    "chmod +x"
)

die() {
    echo "Ошибка: $*" >&2
    exit 1
}

[ -f "$history_file" ] || die "файл не найден: $history_file"
[ -r "$history_file" ] || die "нет прав на чтение файла: $history_file"
[ -w "$history_file" ] || die "нет прав на запись в файл: $history_file"

tmp_file=$(mktemp "${TMPDIR:-/tmp}/clean_bash_history.XXXXXX") || die "не удалось создать временный файл"
trap 'rm -f "$tmp_file"' EXIT

awk '
BEGIN {
    patterns[1] = "apt-get install git"
    patterns[2] = "dnf install git"
    patterns[3] = "git clone"
    patterns[4] = "./"
    patterns[5] = "history -d"
    patterns[6] = "chmod +x"
}
{
    remove_line = 0

    for (i = 1; i <= 6; i++) {
        if (index($0, patterns[i]) > 0) {
            remove_line = 1
            break
        }
    }

    if (!remove_line) {
        print
    }
}
' "$history_file" > "$tmp_file" || die "не удалось обработать файл: $history_file"

cat "$tmp_file" > "$history_file" || die "не удалось сохранить файл: $history_file"

echo "История очищена: $history_file"
