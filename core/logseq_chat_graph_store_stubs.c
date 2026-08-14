#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#include <sqlite3.h>
#include <stdio.h>
#include <string.h>

static void fail_sqlite(sqlite3 *db, const char *operation)
{
  char message[1024];
  snprintf(message,
           sizeof(message),
           "SQLite error while %s: %s",
           operation,
           db == NULL ? "unknown error" : sqlite3_errmsg(db));
  if (db != NULL) {
    sqlite3_close(db);
  }
  caml_failwith(message);
}

static sqlite3 *open_database(const char *path)
{
  sqlite3 *db = NULL;
  if (sqlite3_open(path, &db) != SQLITE_OK) {
    fail_sqlite(db, "opening graph database");
  }
  return db;
}

static void execute(sqlite3 *db, const char *sql, const char *operation)
{
  if (sqlite3_exec(db, sql, NULL, NULL, NULL) != SQLITE_OK) {
    fail_sqlite(db, operation);
  }
}

CAMLprim value logseq_chat_graph_store_prepare(value raw_path)
{
  CAMLparam1(raw_path);
  sqlite3 *db = open_database(String_val(raw_path));
  execute(db,
          "create table kvs "
          "(addr INTEGER primary key, content TEXT, addresses JSON)",
          "creating graph kvs table");
  sqlite3_close(db);
  CAMLreturn(Val_unit);
}

CAMLprim value logseq_chat_graph_store_append(value raw_path, value raw_rows)
{
  CAMLparam2(raw_path, raw_rows);
  sqlite3 *db = open_database(String_val(raw_path));
  sqlite3_stmt *statement = NULL;
  const char *sql =
    "insert into kvs (addr, content, addresses) values (?, ?, ?)";

  execute(db, "begin immediate transaction", "starting graph row transaction");
  if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK) {
    execute(db, "rollback transaction", "rolling back graph row transaction");
    fail_sqlite(db, "preparing graph row insert");
  }

  for (value cursor = raw_rows;
       cursor != Val_emptylist;
       cursor = Field(cursor, 1)) {
    value row = Field(cursor, 0);
    value content = Field(row, 1);
    value addresses = Field(row, 2);
    sqlite3_reset(statement);
    sqlite3_clear_bindings(statement);
    if (sqlite3_bind_int64(statement, 1, Long_val(Field(row, 0))) != SQLITE_OK
        || sqlite3_bind_text(statement,
                             2,
                             String_val(content),
                             caml_string_length(content),
                             SQLITE_TRANSIENT) != SQLITE_OK) {
      sqlite3_finalize(statement);
      execute(db, "rollback transaction", "rolling back graph row transaction");
      fail_sqlite(db, "binding graph row");
    }
    if (Is_long(addresses)) {
      if (sqlite3_bind_null(statement, 3) != SQLITE_OK) {
        sqlite3_finalize(statement);
        execute(db, "rollback transaction", "rolling back graph row transaction");
        fail_sqlite(db, "binding graph addresses null");
      }
    } else {
      value address_text = Field(addresses, 0);
      if (sqlite3_bind_text(statement,
                            3,
                            String_val(address_text),
                            caml_string_length(address_text),
                            SQLITE_TRANSIENT) != SQLITE_OK) {
        sqlite3_finalize(statement);
        execute(db, "rollback transaction", "rolling back graph row transaction");
        fail_sqlite(db, "binding graph addresses");
      }
    }
    if (sqlite3_step(statement) != SQLITE_DONE) {
      sqlite3_finalize(statement);
      execute(db, "rollback transaction", "rolling back graph row transaction");
      fail_sqlite(db, "inserting graph row");
    }
  }

  sqlite3_finalize(statement);
  execute(db, "commit transaction", "committing graph row transaction");
  sqlite3_close(db);
  CAMLreturn(Val_unit);
}

CAMLprim value logseq_chat_graph_store_read_row(value raw_path, value raw_addr)
{
  CAMLparam2(raw_path, raw_addr);
  CAMLlocal5(result, pair, content, addresses, address_option);
  sqlite3 *db = open_database(String_val(raw_path));
  sqlite3_stmt *statement = NULL;
  const char *sql = "select content, addresses from kvs where addr = ?";

  if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK) {
    fail_sqlite(db, "preparing graph row read");
  }
  sqlite3_bind_int64(statement, 1, Long_val(raw_addr));
  int rc = sqlite3_step(statement);
  if (rc == SQLITE_DONE) {
    result = Val_none;
  } else if (rc == SQLITE_ROW) {
    const char *content_text = (const char *)sqlite3_column_text(statement, 0);
    content = caml_copy_string(content_text == NULL ? "" : content_text);
    if (sqlite3_column_type(statement, 1) == SQLITE_NULL) {
      address_option = Val_none;
    } else {
      const char *address_text = (const char *)sqlite3_column_text(statement, 1);
      addresses = caml_copy_string(address_text == NULL ? "" : address_text);
      address_option = caml_alloc(1, 0);
      Store_field(address_option, 0, addresses);
    }
    pair = caml_alloc(2, 0);
    Store_field(pair, 0, content);
    Store_field(pair, 1, address_option);
    result = caml_alloc(1, 0);
    Store_field(result, 0, pair);
  } else {
    sqlite3_finalize(statement);
    fail_sqlite(db, "reading graph row");
  }

  sqlite3_finalize(statement);
  sqlite3_close(db);
  CAMLreturn(result);
}
