CC ?= cc
CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic

.PHONY: all clean

all: universal-control-receiver

universal-control-receiver: receiver.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	$(RM) universal-control-receiver
