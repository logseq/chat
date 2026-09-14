open Datascript

type entity_summary =
  { uuid : string
  ; title : string
  }

type status =
  { uuid : string
  ; ident : string option
  ; title : string
  ; icon_type : string option
  ; icon_id : string option
  ; icon_color : string option
  }

type block =
  { uuid : string
  ; title : string
  ; page_id : string
  ; parent_id : string option
  ; order : string option
  ; created_at : int
  ; updated_at : int
  ; sync_status : string
  ; tags : entity_summary list
  ; references : entity_summary list
  ; breadcrumbs : entity_summary list
  ; status : status option
  ; is_asset : bool
  ; asset_type : string option
  ; asset_size : int option
  ; asset_checksum : string option
  ; local_path : string option
  ; journal : (string * int) option
  }

type t =
  { mutable db : db
  ; mutable selected_block_uuid : string option
  ; mutable last_refresh_at : int option
  ; mutable revision : int
  }

val schema : schema
val block_ref : string -> entity_ref
val create : ?storage:storage -> unit -> t
val summaries_json : entity_summary list -> string
val summaries_of_json : string -> entity_summary list
val status_json : status -> string
val status_of_json : string -> status option
val block_exists : t -> string -> bool
val read_block : t -> string -> block option
val journal_metadata : t -> string -> (string * int) option
val all_block_uuids : t -> string list
val all_blocks : t -> block list
val all_statuses : t -> status list
val journal_day_for_ms : int -> int
val block_journal_metadata : t -> block -> (string * int) option
val is_journal_feed_block : t -> block -> bool
val is_recent_feed_block : t -> block -> bool
val compare_recent : block -> block -> int
val compare_outliner : block -> block -> int
val outliner_preorder : page_id:string -> block list -> block list
val journal_blocks : ?include_empty:bool -> t -> block list -> block list
val take : int -> 'a list -> 'a list
val recent_blocks : t -> block list
val selected_block : t -> block option
val commit : t -> tx_op list -> unit
val upsert_statuses : t -> status list -> unit
val upsert_blocks : ?in_recent_feed:bool -> t -> block list -> refresh_time:int -> unit
val select : t -> string -> (unit, string) result
val clear_selection : t -> unit
val journal_page_id_for_ms : int -> string
val upsert_journal_page : ?title:string -> t -> uuid:string -> journal_day:int -> unit
val cache_local_message : t -> uuid:string -> title:string -> now:int -> unit
val cache_local_task : t -> uuid:string -> title:string -> status:status -> now:int -> unit
val cache_local_asset :
  ?target_block_id:string -> t -> uuid:string -> title:string -> asset_type:string
  -> asset_size:int -> asset_checksum:string -> local_path:string -> now:int -> unit
val cache_local_child :
  t -> uuid:string -> title:string -> parent_id:string -> now:int -> (unit, string) result
val pending_blocks : t -> block list
val unsynced_blocks : t -> block list
val mark_block_synced : t -> uuid:string -> (unit, string) result
val mark_block_submitted : t -> uuid:string -> (unit, string) result
val reconcile_created_block :
  ?sync_status:string -> t -> local_uuid:string -> remote_uuid:string
  -> (unit, string) result
val mark_block_sync_failed : t -> uuid:string -> (unit, string) result
val update_block_title : t -> uuid:string -> title:string -> now:int -> (unit, string) result
val update_block_status :
  t -> uuid:string -> status:status -> now:int -> (unit, string) result
val visible_blocks : t -> block list
val visible_from : t -> block list -> block list
