.PHONY: all assets build deps test test-frontend demo-check run

ESBUILD ?= esbuild

all: assets build

assets: plugins/web/web/tuna-input.js

plugins/web/web/tuna-input.js: plugins/web/frontend/tuna-input.ts plugins/web/frontend/input-sender.ts plugins/web/frontend/tuna-keyboard.ts \
		plugins/web/frontend/tuna-pointer.ts Makefile
	$(ESBUILD) $< --bundle --external:datastar --format=esm --minify \
		--platform=browser --target=es2022 --legal-comments=none --outfile=$@

build:
	gerbil build

deps:
	gerbil deps -i

# `gerbil test` exits 0 even when a test fails (TODO.md), so success is
# read from its last line of output, which is OK only when every test passed
# and gerbil test itself exited 0.
test: build test-frontend demo-check
	{ gerbil test ./tuna/... ./plugins/... ./tests/... || echo "make test: gerbil test exited $$?"; } | tee .gerbil/test.out
	@test "$$(tail -n 1 .gerbil/test.out)" = OK || { echo "make test: Gerbil tests failed" >&2; exit 1; }

test-frontend: assets
	node --experimental-vm-modules --test plugins/web/tests/unit/input.test.mjs

run: all
	gerbil env tuna --config starter/init.ss

# The demo configuration loads and its declarations are valid. demo/ is not
# built into the package, so this is what keeps it from rotting.
demo-check: build
	gerbil env tuna check --config demo/init.ss
