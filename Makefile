SCHEME ?= /usr/lib/csv10.4.1/ta6le/scheme
CHEZ_DIR := $(patsubst %/,%,$(dir $(SCHEME)))
OBJ := build/obj
LIBDIRS := src::$(OBJ)/src:lib/chez-lang/src::$(OBJ)/lib/chez-lang/src
TEST_TIMEOUT ?= 60
TESTS := $(sort $(wildcard tests/*-test.sps))
SCRIPT_TESTS := $(sort $(wildcard tests/*-test.sh))
TRANSCRIPTS := $(sort $(wildcard tests/*/*.transcript))
RUNS := $(TESTS:%=run/%) $(SCRIPT_TESTS:%=run/%) $(TRANSCRIPTS:%=run/%)

.PHONY: build test repl exe clean $(RUNS)

# Phony so that Chez, which tracks what each object was built against,
# decides what is stale.
build:
	$(SCHEME) -q --script build.ss

# One process per test, so a crash, a stuck thread or leaked global state
# stays inside its test.
test: $(RUNS)

$(TESTS:%=run/%): run/%: build
	@timeout $(TEST_TIMEOUT) $(SCHEME) --libdirs $(LIBDIRS) --program $(OBJ)/$(*:.sps=.so)

$(SCRIPT_TESTS:%=run/%): run/%: exe
	@timeout $(TEST_TIMEOUT) sh $* build/bin/tuna

$(TRANSCRIPTS:%=run/%): run/%: exe
	@timeout $(TEST_TIMEOUT) sh tests/run-transcript.sh build/bin/tuna $*

repl: build
	$(SCHEME) --libdirs $(LIBDIRS) --compile-imported-libraries

# One file, so running Tuna needs no Chez installation.
exe: build
	mkdir -p build/boot/fasl $(OBJ)/boot build/bin
	$(SCHEME) -q --script boot/make-boot.ss $(CHEZ_DIR)
	cd build/boot && ld -r -b binary -z noexecstack -o boot-files.o petite.boot scheme.boot tuna.boot
	cc -O2 -I$(CHEZ_DIR) -o build/bin/tuna boot/main.c build/boot/boot-files.o \
	  $(CHEZ_DIR)/libkernel.a $(CHEZ_DIR)/liblz4.a $(CHEZ_DIR)/libz.a -lm -ltinfo

clean:
	rm -rf build
