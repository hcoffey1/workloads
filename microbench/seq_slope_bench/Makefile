CC ?= gcc
CFLAGS ?= -O0 -Wall -Wextra -std=c11 -march=native
LDFLAGS ?=
TARGET := seq_slope_bench

all: $(TARGET)

$(TARGET): seq_slope_bench.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
