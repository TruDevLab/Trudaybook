APP      := Trudaybook
VERSION  := 0.1.0
# Номер сборки растёт со временем: так две сборки одной версии различимы.
BUILDNO  := $(shell date +%y%m%d%H%M)
# В macOS лежит GNU Make 3.81: `.SHELLFLAGS` он молча игнорирует, поэтому
# `pipefail` включается прямо в рецепте, а оболочка задаётся явно.
SHELL    := /bin/bash
CONF     ?= debug
# Подпись — своим самоподписанным сертификатом: macOS привязывает выданные
# разрешения (Календарь, Напоминания, Связка ключей) к паре «bundle id +
# корень сертификата», и со стабильным сертификатом они переживают пересборку.
# Свой заводится один раз: `make cert`. Если его нет, но есть сертификат
# Trunook (соседнее приложение того же автора), подписываем им.
ifndef IDENTITY
IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"Trudaybook Dev Signing"' \
	&& echo "Trudaybook Dev Signing" \
	|| { security find-identity -v -p codesigning 2>/dev/null | grep -q '"Trunook Dev Signing"' \
	     && echo "Trunook Dev Signing" || echo "Trudaybook Dev Signing"; })
endif
DEST     ?= /Applications
# Сборка вне папки проекта: на Desktop файлы обрастают расширенными
# атрибутами (codesign считает их мусором), а `.build` забивал бы очередь
# синхронизации iCloud Drive.
BUILDDIR := $(HOME)/Library/Caches/TrudaybookBuild
BUNDLE   := $(BUILDDIR)/$(APP).app
SPMDIR   := $(HOME)/Library/Caches/TrudaybookSPM
TESTDIR  := $(HOME)/Library/Caches/TrudaybookTests
BIN       = $(shell swift build -c $(CONF) --scratch-path $(SPMDIR) --show-bin-path 2>/dev/null)

# Минимум — 15.0, штамп SDK — 26.0. По штампу macOS решает, рисовать ли
# системные элементы в новом оформлении; SwiftPM иначе ставит его равным
# минимуму, и окно выглядит как в старой системе.
SDKSTAMP := -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker 26.0

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all build bundle install run demo stop clean cert identity test icon snapshot-app dmg check-identity

DMG      := $(CURDIR)/$(APP)-$(VERSION).dmg
VOLUME   := $(APP) $(VERSION)
RWDMG    := $(BUILDDIR)/$(APP)-rw.dmg

all: bundle

build:
	set -o pipefail; swift build -c $(CONF) --scratch-path $(SPMDIR) $(SDKSTAMP) 2>&1 | { grep -v "ld: warning: search path" || true; }

# Без сертификата codesign падает невнятно — скажем, что делать.
check-identity:
	@security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(IDENTITY)"' \
		|| { echo "Нет сертификата «$(IDENTITY)» для подписи. Заведите его один раз: make cert"; exit 1; }

bundle: check-identity build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp "$(BIN)/$(APP)" $(BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/Trudaybook.icns $(BUNDLE)/Contents/Resources/Trudaybook.icns
	@rm -rf $(BUNDLE)/Contents/Resources/Backgrounds
	@cp -R Resources/Backgrounds $(BUNDLE)/Contents/Resources/Backgrounds
	@for lang in Resources/*.lproj; do rm -rf $(BUNDLE)/Contents/Resources/$$(basename $$lang); cp -R $$lang $(BUNDLE)/Contents/Resources/; done
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILDNO)" $(BUNDLE)/Contents/Info.plist
	@printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	@xattr -cr $(BUNDLE)
	@codesign --force --sign "$(IDENTITY)" --timestamp=none \
		--entitlements Resources/Trudaybook.entitlements $(BUNDLE)
	@codesign --verify --deep --strict $(BUNDLE) && echo "подписано: $(BUNDLE)"

install: bundle
	@$(MAKE) --no-print-directory stop
	@# Launch Services не успевает заметить подмену бандла сразу после остановки.
	@sleep 1
	@rm -rf "$(DEST)/$(APP).app"
	@cp -R $(BUNDLE) "$(DEST)/$(APP).app"
	@# Spotlight и Launchpad должны знать одну копию — установленную, с иконкой;
	@# рабочая сборка регистрируется, когда её запускают для снимков.
	@$(LSREGISTER) -u $(BUNDLE) 2>/dev/null || true
	@$(LSREGISTER) -f "$(DEST)/$(APP).app"
	@touch "$(DEST)/$(APP).app"
	@# Spotlight индексирует бандл, едва тот скопирован, — раньше, чем Launch
	@# Services узнаёт его иконку, и запоминает стандартную. Переиндексировать
	@# после регистрации и перезапустить панель Spotlight (она поднимется сама).
	@mdimport "$(DEST)/$(APP).app" 2>/dev/null || true
	@killall Spotlight 2>/dev/null || true
	@echo "установлено: $(DEST)/$(APP).app"

## Копия для снимков в тестовом режиме — со своим bundle id: запуски
## для проверки не должны заводить второй «Trudaybook» в Launch Services.
SNAPDIR := $(HOME)/Library/Caches/TrudaybookDemo
SNAPAPP := $(SNAPDIR)/$(APP) Demo.app
snapshot-app: bundle
	@rm -rf "$(SNAPAPP)"
	@mkdir -p "$(SNAPDIR)"
	@cp -R $(BUNDLE) "$(SNAPAPP)"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.trudaybook.Trudaybook.demo" \
		-c "Set :CFBundleName Trudaybook Demo" "$(SNAPAPP)/Contents/Info.plist"
	@codesign --force --sign "$(IDENTITY)" --timestamp=none \
		--entitlements Resources/Trudaybook.entitlements "$(SNAPAPP)"
	@$(LSREGISTER) -u $(BUNDLE) 2>/dev/null || true
	@echo "для снимков: $(SNAPAPP)"

run: install
	@open "$(DEST)/$(APP).app"

## Запуск с тестовой почтой — без аккаунтов, для проверки интерфейса.
demo: install
	@open "$(DEST)/$(APP).app" --args --demo

stop:
	@pkill -x $(APP) 2>/dev/null; true

cert:
	@./scripts/make-cert.sh "Trudaybook Dev Signing"

# Образ для установки: приложение, ярлык «Программы» и «Как установить.txt»
# (приложение подписано самодельным сертификатом — карантин снимается вручную).
dmg:
	@$(MAKE) --no-print-directory bundle CONF=release
	@# Оставшийся с прошлого неудачного захода том иначе примонтируется
	@# вторым, под именем с единицей на конце, и обставится не он.
	@hdiutil detach -quiet "/Volumes/$(VOLUME)" 2>/dev/null || true
	@rm -rf $(BUILDDIR)/dmg "$(DMG)" "$(RWDMG)"
	@mkdir -p $(BUILDDIR)/dmg/.background
	@cp -R $(BUNDLE) $(BUILDDIR)/dmg/
	@ln -s /Applications $(BUILDDIR)/dmg/Applications
	@cp Resources/dmg-readme.txt "$(BUILDDIR)/dmg/Как установить.txt"
	@mkdir -p $(BUILDDIR)/dmg/.fseventsd
	@touch $(BUILDDIR)/dmg/.fseventsd/no_log
	@swift scripts/make-dmg-background.swift $(VERSION)
	@tiffutil -cathidpicheck build/dmg-background.png build/dmg-background@2x.png \
		-out $(BUILDDIR)/dmg/.background/background.tiff >/dev/null
	@rm -rf build
	@hdiutil create -quiet -volname "$(VOLUME)" -srcfolder $(BUILDDIR)/dmg \
		-fs HFS+ -format UDRW -ov "$(RWDMG)"
	@hdiutil attach -quiet -noverify -noautoopen "$(RWDMG)"
	@osascript scripts/dmg-window.applescript "$(VOLUME)"
	@sync
	@hdiutil detach -quiet "/Volumes/$(VOLUME)"
	@hdiutil convert -quiet "$(RWDMG)" -format UDZO -imagekey zlib-level=9 -o "$(DMG)"
	@rm -rf $(BUILDDIR)/dmg "$(RWDMG)"
	@echo "образ собран: $(DMG)"
	@shasum -a 256 "$(DMG)"

identity:
	@security find-identity -v -p codesigning

test:
	swift test --scratch-path $(TESTDIR)

clean:
	@rm -rf $(BUILDDIR) $(SPMDIR) $(TESTDIR) .build

# Перевод: какие русские строки не помечены и каким ключам нет перевода.
strings:
	@rm -rf $(BUILDDIR)/strings && mkdir -p $(BUILDDIR)/strings
	@# Свои модули — заново: инкрементальная сборка выгружает строки только перекомпилированных файлов.
	@rm -rf $(SPMDIR)-strings/out/Intermediates.noindex/Trudaybook.build/Debug/Trudaybook*.build
	@swift build -c debug --scratch-path $(SPMDIR)-strings -Xswiftc -emit-localized-strings \
		-Xswiftc -emit-localized-strings-path -Xswiftc $(BUILDDIR)/strings 2>&1 | grep -E "error" || true
	@python3 scripts/localization.py $(BUILDDIR)/strings Sources

# Готовые фоны-текстуры рисуются кодом: поправить scripts/make-textures.swift.
textures:
	@mkdir -p $(BUILDDIR)
	@swiftc -O -swift-version 5 scripts/make-textures.swift -o $(BUILDDIR)/make-textures
	@$(BUILDDIR)/make-textures Resources/Backgrounds

# Иконка рисуется кодом: поправить scripts/make-icon.swift и пересобрать.
icon:
	@swift scripts/make-icon.swift
	@iconutil -c icns build/Trudaybook.iconset -o Resources/Trudaybook.icns
	@rm -rf build
	@echo "иконка: Resources/Trudaybook.icns"
