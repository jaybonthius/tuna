.PHONY: all assets build deps test test-frontend run

ESBUILD ?= esbuild

all: assets build

assets: web/tuna-keyboard.js

web/tuna-keyboard.js: frontend/tuna-keyboard.ts Makefile
	$(ESBUILD) $< --bundle --external:datastar --format=esm --minify \
		--platform=browser --target=es2022 --legal-comments=none --outfile=$@

build:
	gerbil build

deps:
	gerbil deps -i

test: build test-frontend
	gerbil test ./tuna/...

test-frontend: assets
	node --experimental-vm-modules --test tests/keyboard.test.mjs

run: all
	gerbil env tuna
