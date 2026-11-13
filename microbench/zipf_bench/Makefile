CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -std=gnu11 -march=native
LDFLAGS ?= -pthread -lm
TARGET := zipf_bench

all: $(TARGET)

$(TARGET): zipf_bench.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
