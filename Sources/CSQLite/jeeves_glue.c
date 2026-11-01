#include "CSQLite.h"
#include "sqlite-vec.h"

int jeeves_register_sqlite_vec(void) {
  // sqlite3_auto_extension ignores duplicate registrations.
  return sqlite3_auto_extension((void (*)(void))sqlite3_vec_init);
}

const char *jeeves_sqlite_vec_version(void) { return SQLITE_VEC_VERSION; }

sqlite3_destructor_type jeeves_sqlite_transient(void) { return SQLITE_TRANSIENT; }
