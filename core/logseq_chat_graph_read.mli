module Int_set : Set.S with type elt = int
module String_set : Set.S with type elt = string

type sidebar_page =
  { uuid : string
  ; title : string
  }

type sidebar_pages =
  { favorites : sidebar_page list
  ; recent_pages : sidebar_page list
  }

val value : Datascript.db -> int -> string -> Datascript.value option
val string_value : Datascript.value option -> string option
val protected_string : (string -> (string, string) result) -> Datascript.value option -> string option
val uuid_value : Datascript.value option -> string option
val int_value : Datascript.value option -> int option
val uuid_for_eid : Datascript.db -> int -> string option
val has_ref : Datascript.db -> int -> string -> int -> bool
val ref_eids : Datascript.db -> int -> string -> int list
val class_descendants : Datascript.db -> int -> Int_set.t
val entity_is_instance_of : Datascript.db -> int -> string -> bool
val entity_summary :
  (string -> (string, string) result) -> Datascript.db -> int -> Logseq_chat_model.entity_summary option
val entity_summaries :
  (string -> (string, string) result) -> Datascript.db -> int -> string
  -> Logseq_chat_model.entity_summary list
val tag_is_visible_in_node : Datascript.db -> int -> bool
val visible_tag_summaries :
  (string -> (string, string) result) -> Datascript.db -> int
  -> Logseq_chat_model.entity_summary list
val breadcrumbs :
  (string -> (string, string) result) -> Datascript.db -> int
  -> Logseq_chat_model.entity_summary list
val status_for_eid :
  (string -> (string, string) result) -> Datascript.db -> int
  -> Logseq_chat_model.status option
val block :
  (string -> (string, string) result) -> Datascript.db -> int
  -> Logseq_chat_model.block option
val take : int -> 'a list -> 'a list
val page_is_hidden : Datascript.db -> Int_set.t -> int -> bool
val page_summary :
  (string -> (string, string) result) -> Datascript.db -> int -> sidebar_page option
val favorite_page_eid : Datascript.db -> int option
val recycle_page_eid : Datascript.db -> int option
val last_recycle_order : Datascript.db -> string option
val favorite_block_eid : Datascript.db -> string -> int option
val favorite_block_uuid : Datascript.db -> string -> string option
val page_is_favorite : Datascript.db -> string -> bool
val last_favorite_order : Datascript.db -> string option
val built_in_class : Datascript.db -> int -> bool
val sidebar_pages :
  ?decrypt_title:(string -> (string, string) result) -> Datascript.db -> sidebar_pages
val page_block :
  (string -> (string, string) result) -> Datascript.db -> int
  -> Logseq_chat_model.block option
val tag_available_for_completion : Datascript.db -> int -> bool
val tag_last_used : Datascript.db -> int -> int
val tag_pages :
  ?decrypt_title:(string -> (string, string) result) -> Datascript.db -> sidebar_page list
val node_is_tag : Datascript.db -> string -> bool
val node_is_property : Datascript.db -> string -> bool
val unique_named_uuid : ?require_tag:bool -> Datascript.db -> string -> string option
val normalize_title_text :
  ?create_tag:(string -> string option) -> Datascript.db -> uuid:string -> string -> string
val normalize_titles_creating_tags :
  Datascript.db -> fresh_uuid:(unit -> string) -> uuid:string -> string list
  -> string list * (string * string) list
val compare_blocks : Logseq_chat_model.block -> Logseq_chat_model.block -> int
val compare_journal_blocks : Logseq_chat_model.block -> Logseq_chat_model.block -> int
val related_candidate_is_visible : Datascript.db -> int -> bool
val blocks_referencing :
  ?decrypt_title:(string -> (string, string) result) -> Datascript.db -> attr:string -> string
  -> Logseq_chat_model.block list
val blocks_for_page :
  ?decrypt_title:(string -> (string, string) result) -> Datascript.db -> string
  -> Logseq_chat_model.block list
val node_destination :
  ?decrypt_title:(string -> (string, string) result) -> Datascript.db -> string
  -> (sidebar_page * bool) option
val objects_for_tag :
  ?decrypt_title:(string -> (string, string) result) -> Datascript.db -> string
  -> Logseq_chat_model.block list
val references_for_node :
  ?decrypt_title:(string -> (string, string) result) -> Datascript.db -> string
  -> Logseq_chat_model.block list
val recent_journal_page_ids : ?limit:int -> Datascript.db -> int list
val journal_page_count : Datascript.db -> int
val journal_page_uuid : Datascript.db -> journal_day:int -> string option
val blocks :
  ?decrypt_title:(string -> (string, string) result) -> ?journal_limit:int -> Datascript.db
  -> Logseq_chat_model.block list
