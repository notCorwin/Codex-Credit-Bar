.PHONY: build test app clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

clean:
	swift package clean
	rm -rf dist
