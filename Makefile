APP_NAME := DriveCheckMenu
APP_DIR := build/$(APP_NAME).app

.PHONY: all app build run test install uninstall clean icon

all: app

## Baut das App-Bundle unter build/DriveCheckMenu.app
app:
	./scripts/build-app.sh

build: app

## Baut und startet die App
run: app
	open "$(APP_DIR)"

## Führt die Unit-Tests aus
test:
	swift test

## Erzeugt das App-Icon neu
icon:
	swift scripts/make-icns.swift

## Installiert die App nach /Applications (für zuverlässigen Login-Start)
install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" "/Applications/$(APP_NAME).app"
	@echo "Installiert: /Applications/$(APP_NAME).app"

uninstall:
	rm -rf "/Applications/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf build
	rm -rf Resources/AppIcon.iconset Resources/AppIcon.icns

## Universal Binary (Apple Silicon + Intel)
universal:
	UNIVERSAL=1 ./scripts/build-app.sh
