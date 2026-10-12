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

# `gerbil test` exits 0 even when a test fails (TODO.md), so success is
# read from its last line of output, which is OK only when every test passed
# and gerbil test itself exited 0.
test: build test-frontend
	{ gerbil test ./tuna/... || echo "make test: gerbil test exited $$?"; } | tee .gerbil/test.out
	@test "$$(tail -n 1 .gerbil/test.out)" = OK || { echo "make test: Gerbil tests failed" >&2; exit 1; }

test-frontend: assets
	node --experimental-vm-modules --test tests/keyboard.test.mjs

run: all
	gerbil env tuna
