#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root="$repo_root/_build/android-dependency-sources/sqlite"
host_build="$repo_root/_build/android-sqlite-host"
sqlite_revision=4ebc7fdcf459e8d88eb5b019c2949bda86565528

if [[ ! -d $source_root/.git ]]; then
  git clone https://github.com/sqlite/sqlite.git "$source_root" >&2
fi
git -C "$source_root" fetch origin "$sqlite_revision" >&2
git -C "$source_root" checkout --detach "$sqlite_revision" >&2

if [[ ! -f $host_build/sqlite3.c || ! -f $host_build/sqlite3.h ]]; then
  mkdir -p "$host_build"
  (
    cd "$host_build"
    "$source_root/configure" --disable-shared --disable-static >&2
    make sqlite3.c sqlite3.h >&2
  )
fi

echo "$host_build"
