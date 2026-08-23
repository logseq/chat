open Datascript
module Upstream = Fsrs
module Upstream_models = Models

type rating = Upstream_models.rating =
  | Again
  | Hard
  | Good
  | Easy

type state = Upstream_models.state =
  | New
  | Learning
  | Review
  | Relearning

type card =
  { due : int
  ; stability : float
  ; difficulty : float
  ; elapsed_days : int
  ; scheduled_days : int
  ; reps : int
  ; lapses : int
  ; state : state
  ; last_repeat : int
  ; last_rating : rating option
  }

type due_card =
  { block : Logseq_chat_model.block
  ; children : Logseq_chat_model.block list
  ; card : card
  }

let rating_keyword = function
  | Again -> "again"
  | Hard -> "hard"
  | Good -> "good"
  | Easy -> "easy"
;;

let rating_of_keyword = function
  | "again" -> Some Again
  | "hard" -> Some Hard
  | "good" -> Some Good
  | "easy" -> Some Easy
  | _ -> None
;;

let state_keyword = function
  | New -> "new"
  | Learning -> "learning"
  | Review -> "review"
  | Relearning -> "relearning"
;;

let state_of_keyword = function
  | "new" -> Some New
  | "learning" -> Some Learning
  | "review" -> Some Review
  | "relearning" -> Some Relearning
  | _ -> None
;;

let new_card ~now =
  { due = now
  ; stability = 0.
  ; difficulty = 0.
  ; elapsed_days = 0
  ; scheduled_days = 0
  ; reps = 0
  ; lapses = 0
  ; state = New
  ; last_repeat = now
  ; last_rating = None
  }
;;

let timestamp milliseconds =
  Timedesc.Timestamp.of_float_s (Float.of_int milliseconds /. 1000.)
;;

let milliseconds timestamp =
  timestamp
  |> Timedesc.Timestamp.to_float_s
  |> fun seconds -> int_of_float (Float.round (seconds *. 1000.))
;;

let upstream_card (card : card) : Upstream_models.card =
  { due = timestamp card.due
  ; stability = card.stability
  ; difficulty = card.difficulty
  ; elapsed_days = card.elapsed_days
  ; scheduled_days = card.scheduled_days
  ; reps = card.reps
  ; lapses = card.lapses
  ; state = card.state
  ; last_review = timestamp card.last_repeat
  }
;;

let scheduler = Upstream.create (Parameters.default ())

let repeat ~now card rating =
  let scheduled = Upstream.next scheduler (upstream_card card) (timestamp now) rating in
  let next = scheduled.Upstream_models.card in
  { due = milliseconds next.due
  ; stability = next.stability
  ; difficulty = next.difficulty
  ; elapsed_days = next.elapsed_days
  ; scheduled_days = next.scheduled_days
  ; reps = next.reps
  ; lapses = card.lapses + if rating = Again then 1 else 0
  ; state = next.state
  ; last_repeat = milliseconds next.last_review
  ; last_rating = Some rating
  }
;;

let state_value card =
  let entries =
    [ Keyword "stability", Float card.stability
    ; Keyword "difficulty", Float card.difficulty
    ; Keyword "elapsed-days", Int card.elapsed_days
    ; Keyword "scheduled-days", Int card.scheduled_days
    ; Keyword "reps", Int card.reps
    ; Keyword "lapses", Int card.lapses
    ; Keyword "state", Keyword (state_keyword card.state)
    ; Keyword "last-repeat", Int card.last_repeat
    ]
  in
  let entries =
    match card.last_rating with
    | None -> entries
    | Some rating ->
      (Keyword "logseq/last-rating", Keyword (rating_keyword rating)) :: entries
  in
  Map entries
;;

let map_value key entries =
  List.find_map
    (fun (candidate, value) ->
      match candidate with
      | Keyword candidate when String.equal candidate key -> Some value
      | _ -> None)
    entries
;;

let float_value = function
  | Some (Float value) -> Some value
  | Some (Int value) -> Some (Float.of_int value)
  | _ -> None
;;

let int_value = function
  | Some (Int value) | Some (Instant value) -> Some value
  | _ -> None
;;

let keyword_value = function Some (Keyword value) -> Some value | _ -> None

let card_of_values ~created_at ~due ~state =
  match due, state with
  | Some due, Some (Map entries) ->
    (match
       float_value (map_value "stability" entries),
       float_value (map_value "difficulty" entries),
       int_value (map_value "elapsed-days" entries),
       int_value (map_value "scheduled-days" entries),
       int_value (map_value "reps" entries),
       int_value (map_value "lapses" entries),
       Option.bind (keyword_value (map_value "state" entries)) state_of_keyword,
       int_value (map_value "last-repeat" entries)
     with
     | Some stability, Some difficulty, Some elapsed_days, Some scheduled_days,
       Some reps, Some lapses, Some state, Some last_repeat ->
       let last_rating =
         Option.bind
           (keyword_value (map_value "logseq/last-rating" entries))
           rating_of_keyword
       in
       { due; stability; difficulty; elapsed_days; scheduled_days; reps; lapses; state
       ; last_repeat; last_rating }
     | _ -> new_card ~now:created_at)
  | _ -> new_card ~now:created_at
;;

let card_eid db eid =
  match Datascript.entid db "db/ident" (Keyword "logseq.class/Card") with
  | None -> false
  | Some card_class_eid ->
    let classes = Logseq_chat_graph_read.class_descendants db card_class_eid in
    Logseq_chat_graph_read.ref_eids db eid "block/tags"
    |> List.exists (fun class_eid -> Logseq_chat_graph_read.Int_set.mem class_eid classes)
;;

let card_for_uuid
      ?(decrypt_title = fun value -> Ok value)
      ?page_blocks_for_page
      db
      ~now
      uuid
  =
  match Datascript.entid db "block/uuid" (Uuid uuid) with
  | Some eid when card_eid db eid ->
    Option.map
      (fun block ->
        let page_blocks =
          match page_blocks_for_page with
          | Some load -> load block.Logseq_chat_model.page_id
          | None ->
            Logseq_chat_graph_read.blocks_for_page
              ~decrypt_title
              db
              block.Logseq_chat_model.page_id
        in
        let rec descendants parent_uuid =
          page_blocks
          |> List.filter (fun (candidate : Logseq_chat_model.block) ->
            candidate.Logseq_chat_model.parent_id = Some parent_uuid)
          |> List.concat_map (fun (child : Logseq_chat_model.block) ->
            child :: descendants child.uuid)
        in
        let created_at = if block.Logseq_chat_model.created_at > 0 then block.created_at else now in
        let due =
          Logseq_chat_graph_read.int_value
            (Logseq_chat_graph_read.value db eid "logseq.property.fsrs/due")
        in
        let card =
          card_of_values
            ~created_at
            ~due
            ~state:(Logseq_chat_graph_read.value db eid "logseq.property.fsrs/state")
        in
        { block; children = descendants uuid; card })
      (Logseq_chat_graph_read.block decrypt_title db eid)
  | _ -> None
;;

let due_cards ?(decrypt_title = fun value -> Ok value) db ~now =
  match Datascript.entid db "db/ident" (Keyword "logseq.class/Card") with
  | None -> []
  | Some card_class_eid ->
    let page_blocks = Hashtbl.create 8 in
    let page_blocks_for_page page_uuid =
      match Hashtbl.find_opt page_blocks page_uuid with
      | Some blocks -> blocks
      | None ->
        let blocks =
          Logseq_chat_graph_read.blocks_for_page ~decrypt_title db page_uuid
        in
        Hashtbl.add page_blocks page_uuid blocks;
        blocks
    in
    Logseq_chat_graph_read.class_descendants db card_class_eid
    |> Logseq_chat_graph_read.Int_set.to_seq
    |> Seq.flat_map (fun class_eid ->
      Logseq_chat_datascript_value.datoms_by_ref db Aevt "block/tags" class_eid)
    |> Seq.map (fun datom -> datom.e)
    |> List.of_seq
    |> List.sort_uniq Int.compare
    |> List.filter_map (fun eid ->
      Option.bind (Logseq_chat_graph_read.uuid_for_eid db eid) (fun uuid ->
        Option.bind
          (card_for_uuid ~decrypt_title ~page_blocks_for_page db ~now uuid)
          (fun due_card ->
          if due_card.card.due > now then None else Some due_card)))
    |> List.sort (fun left right ->
      match Int.compare left.card.due right.card.due with
      | 0 -> String.compare left.block.uuid right.block.uuid
      | order -> order)
;;
