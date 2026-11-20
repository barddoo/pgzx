# Project helpers. Every target loads the pgzx environment first, so
# PG_HOME and PGHOST always match the local cluster.

ZIG ?= zig
PGZX ?= pgzx

.PHONY: all build check install test unit start stop clean

all: build

build:
	eval "$$($(PGZX) env)" && $(ZIG) build

check:
	eval "$$($(PGZX) env)" && $(ZIG) build check

install:
	eval "$$($(PGZX) env)" && $(ZIG) build -p "$$PG_HOME"

test:
	eval "$$($(PGZX) env)" && $(ZIG) build pg_regress

unit:
	eval "$$($(PGZX) env)" && $(ZIG) build -p "$$PG_HOME" unit

start:
	$(PGZX) start

stop:
	$(PGZX) stop

clean:
	rm -rf zig-cache zig-out out regression.out regression.diffs results
