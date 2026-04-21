APP_NAME := PennSay
BUILD_ROOT ?= $(HOME)/.voiceinput-build

.PHONY: build run release install clean

build:
	./scripts/build.sh Debug

run:
	./scripts/run.sh

release:
	./scripts/release.sh

install:
	./scripts/build.sh Release
	rm -rf /Applications/$(APP_NAME).app
	cp -R build/Release/$(APP_NAME).app /Applications/$(APP_NAME).app

clean:
	rm -rf build "$(BUILD_ROOT)" .build .tmp doubao-murmur.xcodeproj PennSay.xcodeproj VoiceInput.xcodeproj
