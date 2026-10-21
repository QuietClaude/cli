CC ?= cc
CFLAGS = -std=c11 -Wall -Wextra -Werror -O2
LDFLAGS =
LDLIBS =

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
LDFLAGS += -static
LDLIBS += -lutil
endif

LIB = libquietclaude.a
LIB_OBJ = src/core.o src/terminal.o src/banner.o
HDR = src/banner.h src/core.h src/quietclaude.h

all: qc

lib: $(LIB)

$(LIB): $(LIB_OBJ)
	ar rcs $@ $(LIB_OBJ)

src/%.o: src/%.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

qc: src/launcher.c $(LIB) $(HDR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ src/launcher.c $(LIB) $(LDLIBS)

tests/replay: tests/replay.c $(LIB) $(HDR)
	$(CC) $(CFLAGS) -o $@ tests/replay.c $(LIB) $(LDLIBS)

test: qc tests/replay
	sh tests/run.sh

install: qc
	sh install.sh

uninstall:
	sh uninstall.sh

clean:
	rm -f qc tests/replay $(LIB) $(LIB_OBJ)

.PHONY: all lib test install uninstall clean
