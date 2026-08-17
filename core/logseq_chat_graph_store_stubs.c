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

static void ensure_app_schema(sqlite3 *db)
{
  execute(db,
          "create table if not exists logseq_chat_pending_ops ("
          "sequence integer primary key autoincrement,"
          "operation_id text not null unique,"
          "base_t integer not null,"
          "state text not null,"
          "intent text not null)",
          "creating pending operations table");
  execute(db,
          "create table if not exists logseq_chat_pending_op_dependencies ("
          "operation_id text not null,"
          "depends_on_operation_id text not null,"
          "primary key (operation_id, depends_on_operation_id),"
          "foreign key (operation_id) references logseq_chat_pending_ops(operation_id) on delete cascade,"
          "foreign key (depends_on_operation_id) references logseq_chat_pending_ops(operation_id) on delete cascade)",
          "creating pending operation dependencies table");
  execute(db,
          "create table if not exists logseq_chat_sync_state ("
          "key text primary key, value text not null)",
          "creating app sync state table");
}

CAMLprim value logseq_chat_graph_store_prepare(value raw_path)
{
  CAMLparam1(raw_path);
  sqlite3 *db = open_database(String_val(raw_path));
  execute(db,
          "create table kvs "
          "(addr INTEGER primary key, content TEXT, addresses JSON)",
          "creating graph kvs table");
  ensure_app_schema(db);
  sqlite3_close(db);
  CAMLreturn(Val_unit);
}

CAMLprim value logseq_chat_graph_store_copy_app_tables(value raw_source,
                                                       value raw_destination)
{
  CAMLparam2(raw_source, raw_destination);
  sqlite3 *source = open_database(String_val(raw_source));
  ensure_app_schema(source);
  sqlite3_close(source);

  sqlite3 *destination = open_database(String_val(raw_destination));
  ensure_app_schema(destination);
  char *attach = sqlite3_mprintf("attach database %Q as app_source", String_val(raw_source));
  if (attach == NULL) {
    sqlite3_close(destination);
    caml_failwith("Could not allocate SQLite attach statement");
  }
  execute(destination, attach, "attaching active graph app tables");
  sqlite3_free(attach);
  execute(destination, "begin immediate transaction", "starting app table copy");
  execute(destination,
          "insert into main.logseq_chat_pending_ops "
          "(sequence, operation_id, base_t, state, intent) "
          "select sequence, operation_id, base_t, state, intent "
          "from app_source.logseq_chat_pending_ops order by sequence",
          "copying pending operations");
  execute(destination,
          "insert into main.logseq_chat_pending_op_dependencies "
          "(operation_id, depends_on_operation_id) "
          "select operation_id, depends_on_operation_id "
          "from app_source.logseq_chat_pending_op_dependencies",
          "copying pending operation dependencies");
  execute(destination,
          "insert into main.logseq_chat_sync_state (key, value) "
          "select key, value from app_source.logseq_chat_sync_state",
          "copying app sync state");
  execute(destination, "commit transaction", "committing app table copy");
  execute(destination, "detach database app_source", "detaching active graph app tables");
  sqlite3_close(destination);
  CAMLreturn(Val_unit);
}

CAMLprim value logseq_chat_pending_ops_store(value raw_path,
                                             value raw_operation_id,
                                             value raw_base_t,
                                             value raw_state,
                                             value raw_intent)
{
  CAMLparam5(raw_path, raw_operation_id, raw_base_t, raw_state, raw_intent);
  sqlite3 *db = open_database(String_val(raw_path));
  ensure_app_schema(db);
  sqlite3_stmt *statement = NULL;
  const char *sql =
    "insert into logseq_chat_pending_ops (operation_id, base_t, state, intent) "
    "values (?, ?, ?, ?) on conflict(operation_id) do update set "
    "base_t = excluded.base_t, state = excluded.state, intent = excluded.intent";
  if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK
      || sqlite3_bind_text(statement, 1, String_val(raw_operation_id),
                           caml_string_length(raw_operation_id), SQLITE_TRANSIENT) != SQLITE_OK
      || sqlite3_bind_int64(statement, 2, Long_val(raw_base_t)) != SQLITE_OK
      || sqlite3_bind_text(statement, 3, String_val(raw_state),
                           caml_string_length(raw_state), SQLITE_TRANSIENT) != SQLITE_OK
      || sqlite3_bind_text(statement, 4, String_val(raw_intent),
                           caml_string_length(raw_intent), SQLITE_TRANSIENT) != SQLITE_OK
      || sqlite3_step(statement) != SQLITE_DONE) {
    sqlite3_finalize(statement);
    fail_sqlite(db, "storing pending operation");
  }
  sqlite3_finalize(statement);
  sqlite3_close(db);
  CAMLreturn(Val_unit);
}

CAMLprim value logseq_chat_pending_ops_list(value raw_path)
{
  CAMLparam1(raw_path);
  CAMLlocal5(result, cell, row, operation_id, state);
  CAMLlocal1(intent);
  sqlite3 *db = open_database(String_val(raw_path));
  ensure_app_schema(db);
  sqlite3_stmt *statement = NULL;
  const char *sql =
    "select operation_id, base_t, state, intent "
    "from logseq_chat_pending_ops order by sequence desc";
  result = Val_emptylist;
  if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK) {
    fail_sqlite(db, "preparing pending operation list");
  }
  int rc = SQLITE_OK;
  while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
    operation_id = caml_copy_string((const char *)sqlite3_column_text(statement, 0));
    state = caml_copy_string((const char *)sqlite3_column_text(statement, 2));
    intent = caml_copy_string((const char *)sqlite3_column_text(statement, 3));
    row = caml_alloc(4, 0);
    Store_field(row, 0, operation_id);
    Store_field(row, 1, Val_long(sqlite3_column_int64(statement, 1)));
    Store_field(row, 2, state);
    Store_field(row, 3, intent);
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, row);
    Store_field(cell, 1, result);
    result = cell;
  }
  if (rc != SQLITE_DONE) {
    sqlite3_finalize(statement);
    fail_sqlite(db, "reading pending operation list");
  }
  sqlite3_finalize(statement);
  sqlite3_close(db);
  CAMLreturn(result);
}

static void pending_operation_command(value raw_path,
                                      value raw_operation_id,
                                      value raw_value,
                                      const char *sql,
                                      const char *operation)
{
  sqlite3 *db = open_database(String_val(raw_path));
  ensure_app_schema(db);
  sqlite3_stmt *statement = NULL;
  if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK
      || (Is_block(raw_value)
          && sqlite3_bind_text(statement, 1, String_val(Field(raw_value, 0)),
                               caml_string_length(Field(raw_value, 0)), SQLITE_TRANSIENT) != SQLITE_OK)
      || sqlite3_bind_text(statement, Is_block(raw_value) ? 2 : 1,
                           String_val(raw_operation_id),
                           caml_string_length(raw_operation_id), SQLITE_TRANSIENT) != SQLITE_OK
      || sqlite3_step(statement) != SQLITE_DONE) {
    sqlite3_finalize(statement);
    fail_sqlite(db, operation);
  }
  sqlite3_finalize(statement);
  sqlite3_close(db);
}

CAMLprim value logseq_chat_pending_ops_set_state(value raw_path,
                                                 value raw_operation_id,
                                                 value raw_state)
{
  CAMLparam3(raw_path, raw_operation_id, raw_state);
  CAMLlocal1(state_option);
  state_option = caml_alloc(1, 0);
  Store_field(state_option, 0, raw_state);
  pending_operation_command(raw_path, raw_operation_id, state_option,
                            "update logseq_chat_pending_ops set state = ? where operation_id = ?",
                            "updating pending operation state");
  CAMLreturn(Val_unit);
}

CAMLprim value logseq_chat_pending_ops_remove(value raw_path, value raw_operation_id)
{
  CAMLparam2(raw_path, raw_operation_id);
  pending_operation_command(raw_path, raw_operation_id, Val_none,
                            "delete from logseq_chat_pending_ops where operation_id = ?",
                            "removing pending operation");
  CAMLreturn(Val_unit);
}

CAMLprim value logseq_chat_graph_store_append(value raw_path, value raw_rows)
{
  CAMLparam2(raw_path, raw_rows);
  sqlite3 *db = open_database(String_val(raw_path));
  sqlite3_stmt *statement = NULL;
  const char *sql =
    "insert into kvs (addr, content, addresses) values (?, ?, ?) "
    "on conflict(addr) do update set content = excluded.content, "
    "addresses = excluded.addresses";

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

CAMLprim value logseq_chat_graph_store_list_addresses(value raw_path)
{
  CAMLparam1(raw_path);
  CAMLlocal2(result, cell);
  sqlite3 *db = open_database(String_val(raw_path));
  sqlite3_stmt *statement = NULL;
  const char *sql = "select addr from kvs order by addr desc";
  result = Val_emptylist;

  if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK) {
    fail_sqlite(db, "preparing graph address list");
  }
  int rc = SQLITE_OK;
  while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, Val_long(sqlite3_column_int64(statement, 0)));
    Store_field(cell, 1, result);
    result = cell;
  }
  if (rc != SQLITE_DONE) {
    sqlite3_finalize(statement);
    fail_sqlite(db, "reading graph address list");
  }
  sqlite3_finalize(statement);
  sqlite3_close(db);
  CAMLreturn(result);
}

CAMLprim value logseq_chat_graph_store_delete(value raw_path, value raw_addresses)
{
  CAMLparam2(raw_path, raw_addresses);
  sqlite3 *db = open_database(String_val(raw_path));
  sqlite3_stmt *statement = NULL;
  const char *sql = "delete from kvs where addr = ?";

  execute(db, "begin immediate transaction", "starting graph row deletion");
  if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK) {
    execute(db, "rollback transaction", "rolling back graph row deletion");
    fail_sqlite(db, "preparing graph row deletion");
  }
  for (value cursor = raw_addresses;
       cursor != Val_emptylist;
       cursor = Field(cursor, 1)) {
    sqlite3_reset(statement);
    sqlite3_clear_bindings(statement);
    if (sqlite3_bind_int64(statement, 1, Long_val(Field(cursor, 0))) != SQLITE_OK
        || sqlite3_step(statement) != SQLITE_DONE) {
      sqlite3_finalize(statement);
      execute(db, "rollback transaction", "rolling back graph row deletion");
      fail_sqlite(db, "deleting graph row");
    }
  }
  sqlite3_finalize(statement);
  execute(db, "commit transaction", "committing graph row deletion");
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
