SCHEME ?= /usr/lib/csv10.4.1/ta6le/scheme
CHEZ_DIR := $(patsubst %/,%,$(dir $(SCHEME)))
OBJ := build/obj
LIBDIRS := src::$(OBJ)/src:lib/chez-lang/src::$(OBJ)/lib/chez-lang/src
TEST_TIMEOUT ?= 60
BROWSER_TEST_TIMEOUT ?= 300
BROWSER_TESTS := $(sort $(wildcard tests/*-browser-test.sh))
SCRIPT_TESTS := $(filter-out $(BROWSER_TESTS),$(sort $(wildcard tests/*-test.sh)))
TRANSCRIPTS := $(sort $(wildcard tests/*/*.transcript))
RUNS := run/test-files $(SCRIPT_TESTS:%=run/%) $(BROWSER_TESTS:%=run/%) $(TRANSCRIPTS:%=run/%)

.PHONY: build test repl exe clean $(RUNS)

# Phony so that Chez, which tracks what each object was built against,
# decides what is stale.
build:
	$(SCHEME) -q --script build.ss

# One process per test, so a crash, a stuck thread or leaked global state
# stays inside its test.
test: $(RUNS)

run/test-files: exe
	@timeout 1800 build/bin/tuna --test tests start plugins/*

$(SCRIPT_TESTS:%=run/%): run/%: exe
	@timeout $(TEST_TIMEOUT) sh $* build/bin/tuna

$(BROWSER_TESTS:%=run/%): run/%: exe
	@timeout $(BROWSER_TEST_TIMEOUT) sh $* build/bin/tuna

$(TRANSCRIPTS:%=run/%): run/%: exe
	@TEST_TIMEOUT=$(TEST_TIMEOUT) sh tests/run-transcript.sh build/bin/tuna $*

# faces' browser test highlights with tree-sitter-python at the commit
# Tuna pins, built from the copy chez-treesitter vendors, so no test
# fetches it.
PYTHON_GRAMMAR := build/test-grammars/libtree-sitter-python-293fdc02038e.so

$(PYTHON_GRAMMAR): | exe
	sh tests/build-grammar.sh build/bin/libraries/chez-treesitter/vendor/tree-sitter-python \
	  293fdc02038ee2bf0e2e206711b69c90ac0d413f $@

run/tests/faces-browser-test.sh: $(PYTHON_GRAMMAR)

repl: build
	$(SCHEME) --libdirs $(LIBDIRS) --compile-imported-libraries

# One file, so running Tuna needs no Chez installation. Tuna's own
# plugins go beside it as source, since a module is unloaded, reloaded
# and evaluated from its file. build/bin/libraries is kept, since
# building H2O and libghostty again takes minutes.
exe: build
	mkdir -p build/boot/fasl $(OBJ)/boot build/bin
	$(SCHEME) -q --script boot/make-boot.ss $(CHEZ_DIR)
	cd build/boot && ld -r -b binary -z noexecstack -o boot-files.o petite.boot scheme.boot tuna.boot
	cc -O2 -I$(CHEZ_DIR) -o build/bin/tuna boot/main.c build/boot/boot-files.o \
	  $(CHEZ_DIR)/libkernel.a $(CHEZ_DIR)/liblz4.a $(CHEZ_DIR)/libz.a -lm -ltinfo
	rm -rf build/bin/start build/bin/start-cache build/bin/plugins build/bin/plugins-cache
	cp -R start/src build/bin/start
	cp start/tuna.deps build/bin/start/tuna.deps
	cp -R plugins build/bin/plugins
	sh boot/build-plugins.sh build/bin/tuna

clean:
	rm -rf build
