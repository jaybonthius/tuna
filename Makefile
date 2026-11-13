SCHEME ?= /usr/lib/csv10.4.1/ta6le/scheme
CHEZ_DIR := $(patsubst %/,%,$(dir $(SCHEME)))
OBJ := build/obj
LIBDIRS := src::$(OBJ)/src:lib/chez-lang/src::$(OBJ)/lib/chez-lang/src
TEST_LIBDIRS := $(LIBDIRS):tests/lib::$(OBJ)/tests/lib
TEST_TIMEOUT ?= 60
TESTS := $(sort $(wildcard tests/*-test.sps))
SCRIPT_TESTS := $(sort $(wildcard tests/*-test.sh))
TRANSCRIPTS := $(sort $(wildcard tests/*/*.transcript))
RUNS := $(TESTS:%=run/%) $(SCRIPT_TESTS:%=run/%) $(TRANSCRIPTS:%=run/%)

.PHONY: build test bench repl exe clean $(RUNS)

# Phony so that Chez, which tracks what each object was built against,
# decides what is stale.
build:
	$(SCHEME) -q --script build.ss

# One process per test, so a crash, a stuck thread or leaked global state
# stays inside its test.
test: $(RUNS)

$(TESTS:%=run/%): run/%: build
	@timeout $(TEST_TIMEOUT) $(SCHEME) --libdirs $(TEST_LIBDIRS) --program $(OBJ)/$(*:.sps=.so)

$(SCRIPT_TESTS:%=run/%): run/%: exe
	@timeout $(TEST_TIMEOUT) sh $* build/bin/tuna

$(TRANSCRIPTS:%=run/%): run/%: exe
	@timeout $(TEST_TIMEOUT) sh tests/run-transcript.sh build/bin/tuna $*

# Every benchmark runs, so that one failed gate hides none of the others.
bench: exe
	@status=0; \
	sh bench/hot-paths.sh build/bin/tuna || status=1; \
	sh bench/tick.sh build/bin/tuna || status=1; \
	sh bench/startup.sh build/bin/tuna $(SCHEME) || status=1; \
	sh bench/libraries.sh build/bin/tuna || status=1; \
	sh bench/reload.sh build/bin/tuna || status=1; \
	sh bench/document.sh build/bin/tuna || status=1; \
	sh bench/buffers.sh build/bin/tuna || status=1; \
	sh bench/commands.sh build/bin/tuna || status=1; \
	sh bench/web.sh build/bin/tuna || status=1; \
	sh bench/views.sh build/bin/tuna || status=1; \
	sh bench/kill-ring.sh build/bin/tuna || status=1; \
	sh bench/keys.sh build/bin/tuna || status=1; \
	sh bench/repeat.sh build/bin/tuna || status=1; \
	sh bench/layout.sh build/bin/tuna || status=1; \
	sh bench/layout-tabs.sh build/bin/tuna || status=1; \
	sh bench/layout-scroll-float.sh build/bin/tuna || status=1; \
	sh bench/part-mode.sh build/bin/tuna || status=1; \
	sh bench/saved.sh build/bin/tuna || status=1; \
	sh bench/files.sh build/bin/tuna || status=1; \
	sh bench/display.sh build/bin/tuna || status=1; \
	sh bench/undo.sh build/bin/tuna || status=1; \
	sh bench/editing.sh build/bin/tuna || status=1; \
	sh bench/mouse.sh build/bin/tuna || status=1; \
	sh bench/ui.sh build/bin/tuna || status=1; \
	sh bench/modes.sh build/bin/tuna || status=1; \
	exit $$status

repl: build
	$(SCHEME) --libdirs $(LIBDIRS) --compile-imported-libraries

# One file, so running Tuna needs no Chez installation. Tuna's own
# library goes beside it as source, since a module is unloaded, reloaded
# and evaluated from its file.
exe: build
	mkdir -p build/boot/fasl $(OBJ)/boot build/bin
	$(SCHEME) -q --script boot/make-boot.ss $(CHEZ_DIR)
	cd build/boot && ld -r -b binary -z noexecstack -o boot-files.o petite.boot scheme.boot tuna.boot
	cc -O2 -I$(CHEZ_DIR) -o build/bin/tuna boot/main.c build/boot/boot-files.o \
	  $(CHEZ_DIR)/libkernel.a $(CHEZ_DIR)/liblz4.a $(CHEZ_DIR)/libz.a -lm -ltinfo
	rm -rf build/bin/plugins build/bin/libraries
	sh boot/copy-library.sh plugins build/bin/plugins
	sh boot/copy-library.sh libraries build/bin/libraries
	sh boot/build-plugins.sh build/bin/tuna

# Tuna's build writes into its libraries' checkouts, beside their sources.
clean:
	rm -rf build
	for library in libraries/*/; do git -C "$$library" clean -fdxq; done
