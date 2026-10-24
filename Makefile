.PHONY: all assets build deps test test-frontend demo-check run tokens voice-worker voice-worker-check

ESBUILD ?= esbuild

all: assets build

assets: plugins/web/web/tuna-input.js plugins/microphone/web/microphone.js plugins/microphone/web/microphone-worklet.js

plugins/web/web/tuna-input.js: plugins/web/frontend/tuna-input.ts plugins/web/frontend/input-sender.ts plugins/web/frontend/tuna-keyboard.ts \
		plugins/web/frontend/tuna-pointer.ts plugins/web/frontend/tuna-scroll.ts \
		plugins/web/frontend/tuna-clipboard.ts Makefile
	$(ESBUILD) $< --bundle --external:datastar --format=esm --minify \
		--platform=browser --target=es2022 --legal-comments=none --outfile=$@

# The microphone plugin's page script and its AudioWorklet, which the page
# loads as a separate module.
plugins/microphone/web/microphone.js: plugins/microphone/frontend/microphone.ts Makefile
	$(ESBUILD) $< --bundle --external:datastar --format=esm --minify \
		--platform=browser --target=es2022 --legal-comments=none --outfile=$@

plugins/microphone/web/microphone-worklet.js: plugins/microphone/frontend/microphone-worklet.ts Makefile
	$(ESBUILD) $< --bundle --format=esm --minify \
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

# Regenerate the design tokens from their Stellar config with the owner's
# licensed Stellar binary: make tokens STELLAR=/absolute/path/to/stellar.
# The binary and its key are not in this repository, and nothing else
# needs them: the generated CSS is committed, and building, testing and
# running Tuna only read it.
STELLAR ?= stellar

tokens:
	cd plugins/design-tokens/tokens && $(STELLAR) gen --input stellar.config.json

# The speech worker (plugins/voice/worker/) links the owner's local
# gerbil-parakeet install, so only this target builds it; make and make test
# never need parakeet or a model. parakeet-compile supplies the native
# include and link flags and a relative library path. gxc writes the
# worker's compiled module and every static module's C into GERBIL_PATH, so
# it compiles against a copy of the install's static modules, beside a link
# to its parakeet modules, and leaves the install itself untouched.
PARAKEET_GERBIL_PATH ?= /home/jay/Code/workbench-gerbil/gerbil-parakeet/.install-check/local
VOICE_MODEL ?= /home/jay/Code/workbench-gerbil/gerbil-parakeet/.deps/models/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf
VOICE_SPEECH ?= /home/jay/Code/workbench-gerbil/gerbil-parakeet/.deps/fixtures/speech.f32
VOICE_WORKER_GERBIL_PATH = $(CURDIR)/.gerbil/voice-worker

voice-worker: .gerbil/bin/tuna-voice-worker

.gerbil/bin/tuna-voice-worker: plugins/voice/worker/worker.ss Makefile
	rm -rf $(VOICE_WORKER_GERBIL_PATH)
	mkdir -p $(VOICE_WORKER_GERBIL_PATH)/lib
	ln -s $(PARAKEET_GERBIL_PATH)/lib/parakeet $(VOICE_WORKER_GERBIL_PATH)/lib/parakeet
	cp -pr $(PARAKEET_GERBIL_PATH)/lib/static $(VOICE_WORKER_GERBIL_PATH)/lib/static
	GERBIL_PATH=$(VOICE_WORKER_GERBIL_PATH) $(PARAKEET_GERBIL_PATH)/bin/parakeet-compile $< $@

# Pipe recorded speech through the worker at real-time pace, then at full
# speed, timing each line.
voice-worker-check: voice-worker
	plugins/voice/worker/check.sh .gerbil/bin/tuna-voice-worker $(VOICE_MODEL) $(VOICE_SPEECH) paced
	plugins/voice/worker/check.sh .gerbil/bin/tuna-voice-worker $(VOICE_MODEL) $(VOICE_SPEECH) full

# The demo configuration loads and its declarations are valid. demo/ is not
# built into the package, so this is what keeps it from rotting.
demo-check: build
	gerbil env tuna check --config demo/init.ss
