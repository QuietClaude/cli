CC ?= cc
CFLAGS = -std=c11 -Wall -Wextra -Werror -O2
LDFLAGS =
LDLIBS =

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
LDFLAGS += -static
LDLIBS += -lutil
endif

SRC = src/launcher.c src/terminal.c src/banner.c
HDR = src/banner.h src/quietclaude.h

all: qc

qc: $(SRC) $(HDR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRC) $(LDLIBS)

tests/replay: tests/replay.c src/banner.c src/banner.h
	$(CC) $(CFLAGS) -o $@ tests/replay.c src/banner.c

test: qc tests/replay
	sh tests/run.sh

install: qc
	sh install.sh

clean:
	rm -f qc tests/replay

.PHONY: all test install clean
