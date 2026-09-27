"""Проверка перевода интерфейса (make strings).

python3 scripts/localization.py <stringsdata-dir> Sources [--apply]

1. Русские строки в коде, которых нет в выгрузке компилятора
   (-emit-localized-strings): интерфейс их не переведёт. С --apply они
   оборачиваются в String(localized: ...). EXCLUDE — строки-данные
   (имена групп календарей, папок сервера, журнал), их не трогаем.
2. Ключи из выгрузки, которых нет в Resources/en.lproj и zh-Hans.lproj.
   Новую строку переводят, дописав её в оба Localizable.strings.
"""
import glob
import json
import os
import re
import sys

ls_dir, src_dir = sys.argv[1], sys.argv[2]
RESOURCES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources")
apply = "--apply" in sys.argv

extracted = set()
for f in glob.glob(os.path.join(ls_dir, "*.stringsdata")):
    data = json.load(open(f))
    for entries in data.get("tables", {}).values():
        for e in entries:
            loc = e.get("location", {})
            extracted.add((os.path.basename(data["source"]), loc.get("startingLine"), loc.get("startingColumn")))

CYR = re.compile(r"[А-Яа-яЁё]")
SKIP_LINE = re.compile(r"^\s*(//|///|\*)|DebugLog\.write|\blog\(|log\?\(|print\(|dateFormat|fatalError|precondition|assert")
SKIP_BEFORE = re.compile(r"(defaultValue:\s*$|case\s*$|case\s.*,\s*$|String\(localized:\s*$|LocalizedStringKey\(\s*$|forKey:\s*$|Text\(verbatim:\s*$)")


def literals(line):
    """(start, end) строковых литералов в строке, с учётом \\( ... ) внутри."""
    i, n = 0, len(line)
    while i < n:
        if line.startswith('"""', i):
            return
        if line[i] == '"':
            start = i
            i += 1
            depth = 0
            while i < n:
                c = line[i]
                if c == "\\" and i + 1 < n and line[i + 1] == "(" and depth == 0:
                    depth = 1
                    i += 2
                    continue
                if depth:
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                    elif c == '"':
                        j = line.find('"', i + 1)
                        i = j if j != -1 else n
                    i += 1
                    continue
                if c == "\\":
                    i += 2
                    continue
                if c == '"':
                    yield start, i + 1
                    break
                i += 1
        elif line.startswith("//", i):
            return
        i += 1


# Строки-данные: по ним сравнивают, пишут журнал или это XML — не переводим.
EXCLUDE = {
    ('AccountSettings.swift', '"Exchange напрямую"'),
    ('AccountSettings.swift', '"Exchange через macOS · учётная"'),
    ('AccountSettings.swift', '"Exchange через macOS"'),
    ('AccountSettings.swift', '"На этом Mac"'),
    ('AppModel.swift', '"календари: копия основного календаря Exchange из macOS скрыта"'),
    ('AppModel.swift', '"календарь"'),
    ('AppModel.swift', '"почта \\(account.email)"'),
    ('Attachments.swift', '"Trudaybook-вложения"'),
    ('Backgrounds.swift', '"фон-\\(UUID().uuidString).jpg"'),
    ('ColorDot.swift', '" через macOS"'),
    ('ColorDot.swift', '"Дни рождения из Контактов"'),
    ('ColorDot.swift', '"Другое"'),
    ('ColorDot.swift', '"На этом Mac"'),
    ('ColorDot.swift', '"Подписки"'),
    ('ColorDot.swift', '"календарь коллеги: "'),
    ('ColorDot.swift', '"учётная запись "'),
    ('EWSCalendar.swift', '"Exchange напрямую · \\(account.email)"'),
    ('EWSCalendarRequest.swift', '"<t:Subject>\\(XMLEscape.text(draft.title.isEmpty ? "Новая встреча" : draft.title))</t:Subject>"'),
    ('EWSCalendarRequest.swift', '"<t:Subject>\\(XMLEscape.text(subject.isEmpty ? "Новая встреча" : subject))</t:Subject>"'),
    ('EWSMailProvider.swift', '"Архив"'),
    ('EWSMailProvider.swift', '"архив"'),
    ('EventKitCalendar.swift', '"Exchange через macOS · календарь коллеги: \\(title)"'),
    ('EventKitCalendar.swift', '"Exchange через macOS · учётная запись «\\(title)»"'),
    ('EventKitCalendar.swift', '"Google через macOS · \\(title)"'),
    ('EventKitCalendar.swift', '"\\(title) через macOS"'),
    ('EventKitCalendar.swift', '"Дни рождения из Контактов"'),
    ('EventKitCalendar.swift', '"Другое"'),
    ('EventKitCalendar.swift', '"На этом Mac"'),
    ('EventKitCalendar.swift', '"Подписки"'),
    ('EventKitCalendar.swift', '"Яндекс через macOS · \\(title)"'),
    ('EventKitCalendar.swift', '"яндекс"'),
    ('IMAPMailProvider.swift', '"Архив"'),
    ('IMAPMailProvider.swift', '"Связке"'),
    ('IMAPProtocol.swift', '"литерал"'),
    ('IMAPProtocol.swift', '"пустой атом"'),
    ('MailProvider.swift', '"отв:"'),
    ('MailProvider.swift', '"ответ:"'),
    ('MailLabel.swift', '"важн"'),
    ('MailLabel.swift', '"срочн"'),
    ('MailLabel.swift', '"перепис"'),
    ('MailLabel.swift', '"личн"'),
    ('MailLabel.swift', '"уведомл"'),
    ('MailLabel.swift', '"рассыл"'),
    ('MailLabel.swift', '"реклам"'),
    ('MailLabel.swift', '"новост"'),
    ('MeetingLink.swift', '"Встреча"'),
    ('MeetingLink.swift', '"Телемост"'),
}
SKIP_FILES = {"DemoData.swift"}
total = 0
for path in sorted(glob.glob(os.path.join(src_dir, "**/*.swift"), recursive=True)):
    name = os.path.basename(path)
    lines = open(path).read().split("\n")
    changed = False
    in_multiline = False
    for index, line in enumerate(lines):
        if line.count('"""') % 2 == 1:
            in_multiline = not in_multiline
            continue
        if in_multiline or SKIP_LINE.search(line):
            continue
        spans = [(s, e) for s, e in literals(line) if CYR.search(line[s:e])]
        new = line
        for s, e in reversed(spans):
            if (name, index + 1, s + 1) in extracted:
                continue
            before = line[:s]
            if SKIP_BEFORE.search(before.rstrip()):
                continue
            # («русское», String(localized: «русское»)) — первое для сравнения.
            if line[e:].lstrip().startswith(", String(localized:"):
                continue
            if (name, line[s:e]) in EXCLUDE:
                continue
            total += 1
            print(f"{name}:{index + 1}: {line[s:e]}   <- {before.strip()[-40:]}")
            if apply:
                new = new[:s] + "String(localized: " + new[s:e] + ")" + new[e:]
        if new != line:
            lines[index] = new
            changed = True
    if apply and changed:
        open(path, "w").write("\n".join(lines))
print("всего:", total, file=sys.stderr)


# Ключи без перевода.
def strings_keys(path):
    keys = set()
    if not os.path.exists(path):
        return keys
    for match in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=', open(path, encoding="utf-8").read(), re.M):
        keys.add(match.group(1).encode().decode("unicode_escape").encode("latin-1").decode("utf-8"))
    return keys


needed = set()
for f in glob.glob(os.path.join(ls_dir, "*.stringsdata")):
    data = json.load(open(f))
    if "Demo" in data["source"]:
        continue
    for entries in data.get("tables", {}).values():
        for e in entries:
            if CYR.search(e["key"]):
                needed.add(e["key"])
for lang in ("en", "zh-Hans"):
    have = strings_keys(os.path.join(RESOURCES, f"{lang}.lproj", "Localizable.strings"))
    missing = sorted(needed - have)
    for key in missing:
        print(f"нет перевода ({lang}): {json.dumps(key, ensure_ascii=False)}")
    print(f"{lang}: без перевода {len(missing)}", file=sys.stderr)
