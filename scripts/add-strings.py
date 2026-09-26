"""Дописать переводы в Resources/{en,zh-Hans}.lproj/Localizable.strings,
сохраняя сортировку по ключу.

Вход — TSV из stdin: русский ключ<TAB>английский<TAB>китайский.
Запуск из корня проекта: python3 scripts/add-strings.py < новые.tsv
"""
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
rows = [line.rstrip("\n").split("\t") for line in sys.stdin if line.strip()]
esc = lambda text: text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
LINE = re.compile(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$')
for index, lang in ((1, "en"), (2, "zh-Hans")):
    path = f"{root}/Resources/{lang}.lproj/Localizable.strings"
    lines = open(path, encoding="utf-8").read().splitlines()
    header = [line for line in lines if not LINE.match(line)]
    entries = {LINE.match(line).group(1): LINE.match(line).group(2) for line in lines if LINE.match(line)}
    for row in rows:
        assert len(row) == 3, f"нужно три поля через табуляцию: {row}"
        entries[esc(row[0])] = esc(row[index])
    body = [f'"{key}" = "{value}";' for key, value in sorted(entries.items())]
    open(path, "w", encoding="utf-8").write("\n".join(header + body) + "\n")
    print(lang, len(entries))
