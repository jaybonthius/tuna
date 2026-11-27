SCHEME ?= /usr/lib/csv10.4.1/ta6le/scheme
CHEZ_DIR := $(patsubst %/,%,$(dir $(SCHEME)))
OBJ := build/obj
LIBDIRS := src::$(OBJ)/src:lib/chez-lang/src::$(OBJ)/lib/chez-lang/src

.PHONY: build test check-rebuild repl exe clean

# Phony so that Chez, which tracks what each object was built against,
# decides what is stale.
build:
	$(SCHEME) -q --script build.ss

test: exe
	build/bin/tuna --test tests start plugins/*

# Not part of test, since it builds Tuna a second time.
check-rebuild: exe
	sh boot/check-rebuild.sh

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
