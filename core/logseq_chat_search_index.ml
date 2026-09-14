(* SQLite full-text search index mirroring Logseq's implementation
   (frontend.worker.search and frontend.common.search-fuzzy): the same
   storage layout (a per-graph search/db.sqlite with a blocks table plus a
   blocks_fts FTS5 virtual table using the trigram tokenizer synced by
   triggers), the same upsert/delete statements, and the same query pipeline
   (exact title -> FTS match -> short-query LIKE -> fuzzy LIKE) ranked with
   Logseq's fuzzy score. Vector (semantic) search is intentionally not
   supported. *)

open Datascript

module Ds_value = struct
  let optional_ref_eid = Logseq_chat_lg_graph_support_native.logseq_chat_datascript_value_optional_ref_eid
end

external search_open : string -> unit = "logseq_chat_search_index_open"

external search_upsert
  :  string
  -> (string * string * string) list
  -> unit
  = "logseq_chat_search_index_upsert"

external search_delete : string -> string list -> unit = "logseq_chat_search_index_delete"

external search_query
  :  string
  -> string
  -> string list
  -> (string * string * string) list
  = "logseq_chat_search_index_query"

type t = { path : string }

type result =
  { uuid : string
  ; title : string
  ; page_uuid : string
  ; is_page : bool
  ; score : float
  }

let utf8_length value =
  let length = ref 0 in
  String.iter
    (fun character -> if Char.code character land 0xC0 <> 0x80 then incr length)
    value;
  !length
;;

let utf8_chars value =
  let chars = ref [] in
  let buffer = Buffer.create 4 in
  String.iter
    (fun character ->
      if Char.code character land 0xC0 <> 0x80 && Buffer.length buffer > 0
      then (
        chars := Buffer.contents buffer :: !chars;
        Buffer.clear buffer);
      Buffer.add_char buffer character)
    value;
  if Buffer.length buffer > 0 then chars := Buffer.contents buffer :: !chars;
  List.rev !chars
;;

let contains_substring haystack needle =
  let h = String.length haystack
  and n = String.length needle in
  if n = 0
  then true
  else (
    let rec loop index =
      if index + n > h
      then false
      else if String.equal (String.sub haystack index n) needle
      then true
      else loop (index + 1)
    in
    loop 0)
;;

(* Port of frontend.common.search-fuzzy. Accent folding and NFKC
   normalization are skipped: titles are matched byte-wise, which behaves the
   same for ASCII (case folded) and CJK text. *)
module Fuzzy = struct
  let max_string_length = 1000.

  let clean_str value =
    let lowered = String.lowercase_ascii value in
    let buffer = Buffer.create (String.length lowered) in
    String.iter
      (fun character ->
        match character with
        | '[' | ' ' | '\\' | '/' | '_' | ']' | '(' | ')' -> ()
        | _ -> Buffer.add_char buffer character)
      lowered;
    Buffer.contents buffer
  ;;

  let str_len_distance left right =
    let left_length = float_of_int (utf8_length left) in
    let right_length = float_of_int (utf8_length right) in
    let longest = Float.max left_length right_length in
    let shortest = Float.min left_length right_length in
    if longest = 0. then 1. else 1. -. ((longest -. shortest) /. longest)
  ;;

  let score oquery ostr =
    let query = clean_str oquery in
    let target = clean_str ostr in
    let query_length = String.length query in
    let target_length = String.length target in
    let rec loop query_index target_index mult acc =
      if query_index >= query_length
      then
        acc
        +. str_len_distance query target
        +. (if String.starts_with ~prefix:query target
            then max_string_length +. 10.
            else if contains_substring target query
            then max_string_length
            else 0.)
        +. if target_index >= target_length then 1. else 0.
      else if target_index >= target_length
      then 0.
      else if Char.equal query.[query_index] target.[target_index]
      then loop (query_index + 1) (target_index + 1) (mult + 1) (acc +. float_of_int mult)
      else loop query_index (target_index + 1) 1 (acc -. 0.1)
    in
    loop 0 0 1 0.
  ;;
end

(* Port of get-match-input: normalize boolean operators and quote queries
   containing punctuation as FTS phrase prefixes. *)
let replace_all text pattern replacement =
  Str.global_replace (Str.regexp_string pattern) replacement text
;;

let fts_phrase_input match_input =
  "\"" ^ replace_all match_input "\"" "\"\"" ^ "\"*"
;;

let dangling_boolean_operator match_input =
  try
    ignore (Str.search_forward (Str.regexp {|\(^\| \)\(AND\|OR\|NOT\) *$|}) match_input 0);
    true
  with
  | Not_found -> false
;;

let word_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false
;;

let whitespace_char = function
  | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false
;;

let has_punctuation query =
  String.exists (fun character -> not (word_char character) && not (whitespace_char character)) query
;;

let get_match_input query =
  let match_input =
    query
    |> fun text -> replace_all text " and " " AND "
    |> fun text -> replace_all text " & " " AND "
    |> fun text -> replace_all text " or " " OR "
    |> fun text -> replace_all text " | " " OR "
    |> fun text -> replace_all text " not " " NOT "
  in
  let has_boolean_operator =
    contains_substring match_input "AND"
    || contains_substring match_input "OR"
    || contains_substring match_input "NOT"
  in
  if dangling_boolean_operator match_input
  then fts_phrase_input match_input
  else if
    has_punctuation query
    && (contains_substring match_input "\""
        || (not has_boolean_operator)
        || contains_substring query "/")
  then fts_phrase_input match_input
  else if not (String.equal query match_input)
  then replace_all match_input "," ""
  else match_input
;;

let create ~path =
  let directory = Filename.dirname path in
  (try
     if not (Sys.file_exists directory) then Unix.mkdir directory 0o755
   with
   | Unix.Unix_error _ -> ());
  search_open path;
  { path }
;;

(* Index rows mirroring block->index: id is the block uuid, page is the
   containing page uuid (pages index themselves, so id = page identifies a
   page row), titles have uuid refs replaced with display names, journal
   pages append their journal day. Hidden, built-in, closed-value, blank and
   oversized titles are skipped. *)
let value db eid attr =
  Datascript.datoms db Eavt ~e:eid ~a:attr ()
  |> Seq.uncons
  |> Option.map (fun (datom, _) -> datom.v)
;;

let string_value = function
  | Some (String text) -> Some text
  | _ -> None
;;

let uuid_value = function
  | Some (Uuid text) | Some (String text) -> Some text
  | _ -> None
;;

let row_of_eid db eid =
  let title_for_uuid uuid =
    match Datascript.entid db "block/uuid" (Uuid uuid) with
    | None -> None
    | Some eid ->
      (match string_value (value db eid "block/title") with
       | Some title when not (String.equal (String.trim title) "") -> Some title
       | _ -> None)
  in
  match uuid_value (value db eid "block/uuid"), string_value (value db eid "block/title") with
  | Some uuid, Some title when not (String.equal (String.trim title) "") ->
    let hidden =
      match
        value db eid "logseq.property/built-in?",
        value db eid "block/closed-value-property"
      with
      | Some (Bool true), _ | _, Some _ -> true
      | _ ->
        Logseq_chat_graph_read.page_is_hidden
          db
          Logseq_chat_graph_read.Int_set.empty
          eid
    in
    if hidden || utf8_length title > 10000
    then None
    else (
      let is_page = Option.is_some (string_value (value db eid "block/name")) in
      let page_uuid =
        if is_page
        then uuid
        else (
          match Ds_value.optional_ref_eid db "block/page" (value db eid "block/page") with
          | Some page_eid ->
            Option.value (uuid_value (value db page_eid "block/uuid")) ~default:uuid
          | None -> uuid)
      in
      let title =
        Logseq_chat_lg_graph_support_native.logseq_chat_ref_text_to_text
          title_for_uuid
          title_for_uuid
          title
      in
      let title =
        match value db eid "block/journal-day" with
        | Some (Int day) | Some (Instant day) -> title ^ " " ^ string_of_int day
        | _ -> title
      in
      Some (uuid, title, page_uuid))
  | _ -> None
;;

let row_for_uuid db uuid =
  Option.bind (Datascript.entid db "block/uuid" (Uuid uuid)) (row_of_eid db)
;;

let rows_of_db db =
  Datascript.datoms db Aevt ~a:"block/uuid" ()
  |> Seq.filter_map (fun datom -> row_of_eid db datom.e)
  |> List.of_seq
;;

let referring_uuids db uuid =
  match Datascript.entid db "block/uuid" (Uuid uuid) with
  | None -> []
  | Some eid ->
    Datascript.datoms db Aevt ~a:"block/refs" ~v:(Ref eid) ()
    |> Seq.filter_map (fun datom -> uuid_value (value db datom.e "block/uuid"))
    |> List.of_seq
;;

let refresh_uuids t ~before ~after uuids =
  let affected = Hashtbl.create (List.length uuids * 2) in
  let add uuid = Hashtbl.replace affected uuid () in
  List.iter
    (fun uuid ->
      add uuid;
      List.iter add (referring_uuids before uuid);
      List.iter add (referring_uuids after uuid))
    uuids;
  let affected = Hashtbl.to_seq_keys affected |> List.of_seq in
  if affected <> [] then search_delete t.path affected;
  let wanted = List.filter_map (row_for_uuid after) affected in
  if wanted <> [] then search_upsert t.path wanted
;;

(* Diff the wanted rows against the stored index so refresh stays cheap and
   idempotent: upsert changed rows and delete stale ones. *)
let refresh t db =
  let wanted = rows_of_db db in
  let stored = search_query t.path "select id, page, title from blocks" [] in
  let stored_by_id = Hashtbl.create (List.length stored) in
  List.iter
    (fun (id, page, title) -> Hashtbl.replace stored_by_id id (title, page))
    stored;
  let wanted_ids = Hashtbl.create (List.length wanted) in
  List.iter (fun (id, _, _) -> Hashtbl.replace wanted_ids id ()) wanted;
  let changed =
    List.filter
      (fun (id, title, page) ->
        match Hashtbl.find_opt stored_by_id id with
        | Some (stored_title, stored_page) ->
          not (String.equal stored_title title && String.equal stored_page page)
        | None -> true)
      wanted
  in
  let stale =
    List.filter_map
      (fun (id, _, _) -> if Hashtbl.mem wanted_ids id then None else Some id)
      stored
  in
  if stale <> [] then search_delete t.path stale;
  if changed <> [] then search_upsert t.path changed
;;

let like_escape character =
  match character with
  | "%" | "_" | "\\" -> "\\" ^ character
  | _ -> character
;;

let fuzzy_like_pattern query =
  "%" ^ String.concat "%" (List.map like_escape (utf8_chars query)) ^ "%"
;;

let fuzzy_candidate_limit limit = Int.min 400 (Int.max 40 (4 * limit))

let exact_title_query query = not (String.exists whitespace_char query)

let multi_term_query query =
  try
    ignore (Str.search_forward (Str.regexp {|[^ \t\n][ \t\n]+[^ \t\n]|}) query 0);
    true
  with
  | Not_found -> false
;;

let query_rows t sql binds = try search_query t.path sql binds with Failure _ -> []

let scored query rows =
  List.map
    (fun (id, page, title) ->
      { uuid = id
      ; title
      ; page_uuid = page
      ; is_page = String.equal id page
      ; score = Fuzzy.score query title
      })
    rows
;;

let fuzzy_rows t query ~limit =
  let normalized = Fuzzy.clean_str query in
  let normalized =
    if String.starts_with ~prefix:"#" normalized
    then String.sub normalized 1 (String.length normalized - 1)
    else normalized
  in
  if String.equal (String.trim normalized) ""
  then []
  else (
    let candidate_limit = fuzzy_candidate_limit limit in
    let pattern = fuzzy_like_pattern normalized in
    let page_rows =
      query_rows
        t
        (Printf.sprintf
           "select id, page, title from blocks where id = page and lower(title) like ? \
            escape '\\' limit %d"
           candidate_limit)
        [ pattern ]
    in
    let page_ids = Hashtbl.create (List.length page_rows) in
    List.iter (fun (id, _, _) -> Hashtbl.replace page_ids id ()) page_rows;
    let remaining = candidate_limit - List.length page_rows in
    let block_rows =
      if remaining > 0
      then
        query_rows
          t
          (Printf.sprintf
             "select id, page, title from blocks where lower(title) like ? escape '\\' \
              limit %d"
             (remaining + List.length page_rows))
          [ pattern ]
        |> List.filter (fun (id, _, _) -> not (Hashtbl.mem page_ids id))
        |> List.filteri (fun index _ -> index < remaining)
      else []
    in
    scored normalized (page_rows @ block_rows)
    |> List.filter (fun result -> result.score > 0.))
;;

(* Port of search-blocks (keyword search only): exact title matches first,
   then FTS matches, a LIKE fallback for one/two character queries, and a
   fuzzy LIKE pass, combined with Logseq's ranking boosts (pages +2 keyword
   score and +0.02 combined, tagged blocks +0.01). *)
let search ?(has_tags = fun _uuid -> false) ?(limit = 100) t query =
  let query = String.trim query in
  if String.equal query ""
  then []
  else (
    let match_input = get_match_input query in
    let exact_results =
      if exact_title_query query
      then
        scored
          query
          (query_rows
             t
             (Printf.sprintf
                "select id, page, title from blocks where title = ? COLLATE NOCASE \
                 limit %d"
                limit)
             [ query ])
      else []
    in
    let enough_exact = List.length exact_results >= limit in
    let matched_results =
      if enough_exact
      then []
      else
        scored
          query
          (query_rows
             t
             (Printf.sprintf
                "select id, page, title from blocks_fts where title match ? limit %d"
                limit)
             [ match_input ])
    in
    let non_match_results =
      if utf8_length query <= 2
      then
        scored
          query
          (query_rows
             t
             (Printf.sprintf
                "select id, page, title from blocks_fts where title like ? limit %d"
                limit)
             [ "%" ^ Str.global_replace (Str.regexp "[ \t\n]+") "%" query ^ "%" ])
      else []
    in
    let skip_fuzzy =
      enough_exact || (multi_term_query query && matched_results <> [])
    in
    let fuzzy_results = if skip_fuzzy then [] else fuzzy_rows t query ~limit in
    let combined =
      exact_results @ fuzzy_results @ matched_results @ non_match_results
      |> List.map (fun result ->
        let keyword_score = if result.is_page then result.score +. 2. else result.score in
        let combined_score =
          keyword_score
          +.
          if result.is_page
          then 0.02
          else if has_tags result.uuid
          then 0.01
          else 0.
        in
        result, combined_score)
    in
    let sorted =
      List.stable_sort
        (fun (_, left) (_, right) -> Float.compare right left)
        combined
    in
    let seen = Hashtbl.create 64 in
    sorted
    |> List.filter_map (fun (result, _) ->
      if Hashtbl.mem seen result.uuid
      then None
      else (
        Hashtbl.replace seen result.uuid ();
        Some result))
    |> List.filteri (fun index _ -> index < limit))
;;

type hit =
  { uuid : string
  ; title : string
  ; is_page : bool
  ; page : Logseq_chat_graph_read.sidebar_page option
  ; breadcrumbs : Logseq_chat_model.entity_summary list
  }

(* Search and attach the display context the UI needs: the containing page
   and parent breadcrumbs for block hits. *)
let search_hits ?limit t db query =
  let entity_eid uuid = Datascript.entid db "block/uuid" (Uuid uuid) in
  let has_tags uuid =
    match entity_eid uuid with
    | None -> false
    | Some eid ->
      Datascript.datoms db Eavt ~e:eid ~a:"block/tags" ()
      |> Seq.uncons
      |> Option.is_some
  in
  search ~has_tags ?limit t query
  |> List.map (fun (result : result) ->
    let plain = fun value -> Ok value in
    let page =
      if result.is_page
      then None
      else (
        match entity_eid result.page_uuid with
        | Some page_eid -> Logseq_chat_graph_read.page_summary plain db page_eid
        | None -> None)
    in
    let breadcrumbs =
      if result.is_page
      then []
      else (
        match entity_eid result.uuid with
        | Some eid -> Logseq_chat_graph_read.breadcrumbs plain db eid
        | None -> [])
    in
    { uuid = result.uuid; title = result.title; is_page = result.is_page; page; breadcrumbs })
;;
