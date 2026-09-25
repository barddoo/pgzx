// Included first by every translate-c / @cImport of the Postgres headers.
//
// pg_config.h does "#define restrict __restrict" and the macOS SDK
// (sys/cdefs.h) does "#define __restrict restrict". A conforming preprocessor
// stops expanding that cycle, but the Aro frontend behind zig 0.16 translate-c
// expands it forever: translation spins at 100% CPU and never finishes.
//
// Break the cycle on the SDK side. sys/cdefs.h has an include guard, so after
// this __restrict stays undefined, and Aro treats it as the built-in keyword.
// (pg_config.h has no include guard, so undefining restrict would not stick:
// c.h includes it again.)
#ifndef PGZX_TRANSLATE_PRELUDE_H
#define PGZX_TRANSLATE_PRELUDE_H

#ifdef __APPLE__
#include <sys/cdefs.h>
#undef __restrict
#endif

#endif
