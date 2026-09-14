open Datascript
module LG = Logseq_chat_lg_core_native
module Upstream = Fsrs
module Upstream_models = Models

type due_card =
  { block : Logseq_chat_model.block
  ; children : Logseq_chat_model.block list
  ; card : LG.fsrs_card
  }

let timestamp milliseconds =
  Timedesc.Timestamp.of_float_s (Float.of_int milliseconds /. 1000.)
;;

let milliseconds timestamp =
  timestamp
  |> Timedesc.Timestamp.to_float_s
  |> fun seconds -> int_of_float (Float.round (seconds *. 1000.))
;;

let upstream_card (card : LG.fsrs_card) : Upstream_models.card =
  { due = timestamp card.due
  ; stability = card.stability
  ; difficulty = card.difficulty
  ; elapsed_days = card.elapsed_days
  ; scheduled_days = card.scheduled_days
  ; reps = card.reps
  ; lapses = card.lapses
  ; state =
      (match card.state with
       | LG.New -> Upstream_models.New
       | LG.Learning -> Upstream_models.Learning
       | LG.Review -> Upstream_models.Review
       | LG.Relearning -> Upstream_models.Relearning)
  ; last_review = timestamp card.last_repeat
  }
;;

let scheduler = Upstream.create (Parameters.default ())

let upstream_rating = function
  | LG.Again -> Upstream_models.Again
  | LG.Hard -> Upstream_models.Hard
  | LG.Good -> Upstream_models.Good
  | LG.Easy -> Upstream_models.Easy
;;

let state_of_upstream = function
  | Upstream_models.New -> LG.New
  | Upstream_models.Learning -> LG.Learning
  | Upstream_models.Review -> LG.Review
  | Upstream_models.Relearning -> LG.Relearning
;;

let repeat ~now (card : LG.fsrs_card) (rating : LG.flashcard_rating) =
  let scheduled =
    Upstream.next scheduler (upstream_card card) (timestamp now) (upstream_rating rating)
  in
  let next = scheduled.Upstream_models.card in
  LG.
  { due = milliseconds next.due
  ; stability = next.stability
  ; difficulty = next.difficulty
  ; elapsed_days = next.elapsed_days
  ; scheduled_days = next.scheduled_days
  ; reps = next.reps
  ; lapses = card.lapses + if rating = LG.Again then 1 else 0
  ; state = state_of_upstream next.state
  ; last_repeat = milliseconds next.last_review
  ; last_rating = Some rating
  }
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
          LG.logseq_chat_flashcards_card_of_values
            created_at
            due
            (Logseq_chat_graph_read.value db eid "logseq.property.fsrs/state")
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
