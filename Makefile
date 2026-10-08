# Convenience wrapper around the scripts in scripts/.
#
#   make onetbb        clone + patch + build oneTBB into ./runtime
#   make reproducers   build both minimal reproducers
#   make run           build (if needed) and run them N times (RUNS=5)
#   make clean         remove build outputs
#   make distclean     also remove the oneTBB/hwloc work trees

RUNS ?= 5
PYTHON ?= python3
export PYTHON

.PHONY: all onetbb reproducers run clean distclean

all: reproducers

onetbb:
	bash scripts/build-onetbb.sh

reproducers:
	@if [ ! -e runtime/libtbb.so.12 ]; then bash scripts/build-onetbb.sh; fi
	bash scripts/build-reproducers.sh

run: reproducers
	bash scripts/run.sh $(RUNS)

clean:
	rm -rf runtime
	rm -f standalone/main standalone/main-linked standalone/libwork.so
	rm -f python/apitoflite*.so

distclean: clean
	rm -rf .work
