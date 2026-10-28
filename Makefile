.PHONY: all assets build deps test test-frontend demo-check run tokens voice-worker voice-worker-check voice-command-check terminfo terminal-flood-check

ESBUILD ?= esbuild

# The checkout of gerbil-libghostty (the libghostty-vt binding the terminal
# plugin uses), linked into .gerbil/pkg until it is published. Its first
# build fetches and builds the pinned Ghostty with Zig 0.16.
GERBIL_LIBGHOSTTY ?= /home/jay/Code/workbench-gerbil/gerbil-libghostty

# The checkout of gerbil-md4c (the Markdown parser the markdown plugin
# uses), linked into .gerbil/pkg the same way. md4c is vendored in it, so
# its build needs only a C compiler.
GERBIL_MD4C ?= /home/jay/Code/workbench-gerbil/gerbil-md4c

all: assets terminfo build

assets: plugins/web/web/tuna-input.js plugins/microphone/web/microphone.js plugins/microphone/web/microphone-worklet.js \
	plugins/files/web/files.js plugins/terminal/web/terminal.js

plugins/web/web/tuna-input.js: plugins/web/frontend/tuna-input.ts plugins/web/frontend/input-sender.ts plugins/web/frontend/tuna-keyboard.ts \
		plugins/web/frontend/tuna-pointer.ts plugins/web/frontend/tuna-scroll.ts \
		plugins/web/frontend/tuna-clipboard.ts plugins/web/frontend/tuna-applied.ts Makefile
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

# The terminal plugin's page script.
plugins/terminal/web/terminal.js: plugins/terminal/frontend/terminal.ts Makefile
	$(ESBUILD) $< --bundle --external:datastar --format=esm --minify \
		--platform=browser --target=es2022 --legal-comments=none --outfile=$@

# The files plugin's page script.
plugins/files/web/files.js: plugins/files/frontend/files.ts Makefile
	$(ESBUILD) $< --bundle --external:datastar --format=esm --minify \
		--platform=browser --target=es2022 --legal-comments=none --outfile=$@

build:
	gerbil build

deps:
	gerbil deps -i
	test -e .gerbil/pkg/gerbil-libghostty || gerbil pkg link gerbil-libghostty $(GERBIL_LIBGHOSTTY)
	gerbil pkg build gerbil-libghostty
	test -e .gerbil/pkg/gerbil-md4c || gerbil pkg link gerbil-md4c $(GERBIL_MD4C)
	gerbil pkg build gerbil-md4c

# The terminal plugin's terminfo entry, which its programs find through
# TERMINFO.
terminfo: .gerbil/terminfo/x/xterm-ghostty

.gerbil/terminfo/x/xterm-ghostty: plugins/terminal/terminfo/xterm-ghostty.terminfo
	tic -x -o .gerbil/terminfo $<

# `gerbil test` exits 0 even when a test fails (TODO.md), so success is
# read from its last line of output, which is OK only when every test passed
# and gerbil test itself exited 0.
test: build terminfo test-frontend demo-check
	{ gerbil test ./tuna/... ./plugins/... ./tests/... ./demo/... || echo "make test: gerbil test exited $$?"; } | tee .gerbil/test.out
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
	cd plugins/stylesheets/tokens && $(STELLAR) gen --input stellar.config.json

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
VOICE_THUNDER ?= /home/jay/Code/workbench-gerbil/gerbil-parakeet/.deps/fixtures/thunder.f32
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

# Spoken commands against recordings (plugins/voice/tests/fixtures/), and
# against speech and thunder that name no command: the grammar the demo's
# commands make, what the worker recognizes, each candidate's confidence
# and what voice-command would do with the default settings. A manual
# check, for setting those defaults; make test never runs it.
voice-command-check: build voice-worker
	gerbil env gxi plugins/voice/tests/support/command-check.ss $(CURDIR)/.gerbil/bin/tuna-voice-worker \
		demo/init.ss $(wildcard plugins/voice/tests/fixtures/*.f32) $(VOICE_SPEECH) $(VOICE_THUNDER)

# Heavy output in a terminal: seq 1 2000000, then cat of a 50 MB file
# (made in /tmp when missing), timing the editor's answers meanwhile. A
# manual check; make test never runs it.
terminal-flood-check: build
	gerbil env gxi plugins/terminal/tests/support/flood-check.ss seq
	gerbil env gxi plugins/terminal/tests/support/flood-check.ss cat

# The demo configuration loads and its declarations are valid. demo/ is not
# built into the package, so this is what keeps it from rotting.
demo-check: build
	gerbil env tuna check --config demo/init.ss
