CXX=g++
CXXFLAGS=-I. -g -O3 -W -std=c++17 -fopenmp -march=native -ffast-math
CPPFLAGS += -I../../common
LDLIBS += -lstdc++fs -ldl -pthread
HEADERS := $(wildcard src/*.h) $(wildcard ../../common/regent_regions/*.h)
BINS := bin/eval_remap_only bin/eval_baseline bin/eval_merci

.PHONY: all eval_baseline eval_merci eval_remap_only test
all: $(BINS)
eval_baseline: bin/eval_baseline
eval_merci: bin/eval_merci
eval_remap_only: bin/eval_remap_only
bin/%: src/%.cc $(HEADERS) | bin
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)
bin:
	mkdir -p $@
test: all
	python3 tests/test_regions.py
