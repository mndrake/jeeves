#ifndef JEEVES_CSQLITE_H
#define JEEVES_CSQLITE_H

// The only header Swift imports from this target. SQLite and sqlite-vec are
// compiled statically (SQLITE_CORE), so no loadable-extension API is exposed.
#include "sqlite3.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Registers sqlite-vec as an auto-extension so every connection opened
/// afterwards has the vec0 virtual table and vec_* functions. Idempotent.
/// Returns SQLITE_OK on success.
int jeeves_register_sqlite_vec(void);

/// sqlite-vec's version string, for diagnostics.
const char *jeeves_sqlite_vec_version(void);

/// SQLITE_TRANSIENT cannot be imported into Swift (it is a cast of -1).
sqlite3_destructor_type jeeves_sqlite_transient(void);

#ifdef __cplusplus
}
#endif

#endif
