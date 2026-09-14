type t

val create :
  ?decrypt_title:(string -> (string, string) result) -> Datascript.db -> t
val blocks : t -> Logseq_chat_model.block list
val update : t -> Datascript.db -> Logseq_chat_lg_core_native.sync_change_set -> unit
