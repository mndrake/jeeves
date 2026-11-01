# Vendored C sources

| Component | Version | Source |
|---|---|---|
| SQLite amalgamation | 3540100 | https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip |
| sqlite-vec | 0.1.9 (v0.1.9) | https://github.com/asg017/sqlite-vec |

SHA-256:

```
0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52  sqlite3.c
ba081a47fa02eadc3cf6b16c314b695b84081269349aac722b4efa338fe8fd85  sqlite-vec.c
f3ecc77c77ada795d3de7b5449b82641b5e010085f4e5e50d86c7188c951dbb1  sqlite-vec.h
d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c  include/sqlite3.h
```

Regenerate with `scripts/vendor-sqlite.sh`. SQLite is public domain; sqlite-vec is MIT/Apache-2.0.
