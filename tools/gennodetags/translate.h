// Minimal C surface translated for the gennodetags tool: just enough to
// reflect the NodeTag enum and its T_* values.
//
// Start from postgres.h, not c.h. nodes.h is written to be included after
// postgres.h and relies on its typedefs (e.g. Datum); PG19 moved some of them
// out of c.h, so including c.h alone fails to parse nodes.h.
#include "pgzx_translate_prelude.h"
#include "postgres.h"
#include "utils/palloc.h"
#include "nodes/nodes.h"
