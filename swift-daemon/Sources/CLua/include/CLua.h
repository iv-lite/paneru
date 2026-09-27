// Umbrella for the vendored Lua C API: only the public headers.
// Internal headers (ljumptab.h uses GNU label addresses at file scope and
// must never be parsed as an umbrella member) stay visible to the .c files
// via the target's headerSearchPath, not to importers.
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
