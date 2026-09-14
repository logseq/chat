open Datascript

module Flashcards = Logseq_chat_flashcards
module LG = Logseq_chat_lg_core_native

let fail label = failwith label
let assert_bool label value = if not value then fail label

let assert_int label expected actual =
  if expected <> actual
  then fail (Printf.sprintf "%s: expected %d, got %d" label expected actual)
;;

let assert_float_close label expected actual =
  if Float.abs (expected -. actual) > 0.000_001
  then fail (Printf.sprintf "%s: expected %.6f, got %.6f" label expected actual)
;;

let minute = 60_000
let day = 86_400_000

let () =
  let now = 1_776_000_000_000 in
  let repeated = Flashcards.repeat ~now (LG.logseq_chat_flashcards_new_card now) LG.Again in
  assert_bool "again moves a new card to learning" (repeated.state = LG.Learning);
  assert_int "again increments repetitions" 1 repeated.reps;
  assert_int "again increments lapses" 1 repeated.lapses;
  assert_int "again schedules one minute" (now + minute) repeated.due;
  assert_float_close "upstream initializes difficulty" 7.2102 repeated.difficulty;
  assert_float_close "upstream initializes stability" 0.4072 repeated.stability
;;

let () =
  let now = 1_776_000_000_000 in
  let repeated = Flashcards.repeat ~now (LG.logseq_chat_flashcards_new_card now) LG.Easy in
  assert_bool "easy moves a new card directly to review" (repeated.state = LG.Review);
  assert_int "easy does not add a lapse" 0 repeated.lapses;
  assert_int "easy uses the upstream FSRS v5 initial interval" 15 repeated.scheduled_days;
  assert_int "easy due date uses whole days" (now + (15 * day)) repeated.due
;;

let () =
  let now = 1_776_000_000_000 in
  let original =
    LG.
      { due = now - day
      ; stability = 4.2
      ; difficulty = 5.1
      ; elapsed_days = 2
      ; scheduled_days = 2
      ; reps = 7
      ; lapses = 1
      ; state = Review
      ; last_repeat = now - (2 * day)
      ; last_rating = Some Good
      }
  in
  let decoded =
    LG.logseq_chat_flashcards_card_of_values
      (now - (10 * day))
      (Some original.due)
      (Some (LG.logseq_chat_flashcards_state_value original))
  in
  assert_bool "FSRS state round-trips through the Logseq property map" (decoded = original);
  let repeated = Flashcards.repeat ~now decoded LG.Good in
  assert_bool "a successful review remains in review" (repeated.state = LG.Review);
  assert_int "review increments repetitions" 8 repeated.reps;
  assert_bool "review schedules a future due date" (repeated.due > now);
  assert_bool "review records the selected rating" (repeated.last_rating = Some LG.Good)
;;

let () =
  let started_at = 1_689_432_134_706 in
  let ratings =
    [ LG.Good; LG.Good; LG.Good; LG.Good; LG.Good; LG.Good; LG.Again; LG.Again
    ; LG.Good; LG.Good; LG.Good; LG.Good; LG.Good
    ]
  in
  let intervals, repeated, _ =
    List.fold_left
      (fun (intervals, card, now) rating ->
        let next = Flashcards.repeat ~now card rating in
        next.scheduled_days :: intervals, next, next.due)
      ([], LG.logseq_chat_flashcards_new_card started_at, started_at)
      ratings
  in
  assert_bool
    "adapter follows the upstream OCaml FSRS v5 reference sequence"
    (List.rev intervals = [ 0; 4; 15; 48; 136; 351; 0; 0; 7; 13; 24; 43; 77 ]);
  assert_int "upstream reference repetitions" 13 repeated.reps;
  assert_int "Logseq-compatible lapse tracking" 2 repeated.lapses;
  assert_bool "upstream reference ends in review" (repeated.state = LG.Review)
;;

let one ?unique ?value_type ?(indexed = false) () =
  { cardinality = One; unique; indexed; is_component = false; no_history = false
  ; doc = None; value_type; tuple_attrs = None; tuple_types = None }
;;

let many ?value_type ?(indexed = false) () =
  { (one ?value_type ~indexed ()) with cardinality = Many }
;;

let schema =
  [ "db/ident", one ~unique:Identity ~value_type:KeywordType ~indexed:true ()
  ; "block/uuid", one ~unique:Identity ~value_type:UuidType ~indexed:true ()
  ; "block/title", one ~value_type:StringType ~indexed:true ()
  ; "block/name", one ~value_type:StringType ~indexed:true ()
  ; "block/page", one ~value_type:RefType ~indexed:true ()
  ; "block/parent", one ~value_type:RefType ~indexed:true ()
  ; "block/order", one ~value_type:StringType ~indexed:true ()
  ; "block/tags", many ~value_type:RefType ~indexed:true ()
  ; "block/created-at", one ~value_type:NumberType ~indexed:true ()
  ; "block/updated-at", one ~value_type:NumberType ~indexed:true ()
  ; "logseq.property.class/extends", many ~value_type:RefType ~indexed:true ()
  ; "logseq.property.fsrs/due", one ~indexed:true ()
  ; "logseq.property.fsrs/state", one ~indexed:true ()
  ]
;;

let () =
  let now = 1_776_000_000_000 in
  let future_state =
    LG.logseq_chat_flashcards_state_value
      { (LG.logseq_chat_flashcards_new_card (now - day)) with due = now + day }
  in
  let db =
    empty_db ~schema ()
    |> db_with
         [ Add (Entity_id 1, "db/ident", Keyword "logseq.class/Card")
         ; Add (Entity_id 2, "db/ident", Keyword "user.class/LanguageCard")
         ; Add (Entity_id 2, "logseq.property.class/extends", Ref 1)
         ; Add (Entity_id 10, "block/uuid", Uuid "page")
         ; Add (Entity_id 10, "block/title", String "Page")
         ; Add (Entity_id 10, "block/name", String "page")
         ; Add (Entity_id 11, "block/uuid", Uuid "new-card")
         ; Add (Entity_id 11, "block/title", String "New card")
         ; Add (Entity_id 11, "block/page", Ref 10)
         ; Add (Entity_id 11, "block/parent", Ref 10)
         ; Add (Entity_id 11, "block/order", String "a0")
         ; Add (Entity_id 11, "block/created-at", Int (now - day))
         ; Add (Entity_id 11, "block/updated-at", Int (now - day))
         ; Add (Entity_id 11, "block/tags", Ref 1)
         ; Add (Entity_id 12, "block/uuid", Uuid "due-subclass")
         ; Add (Entity_id 12, "block/title", String "Due subclass card")
         ; Add (Entity_id 12, "block/page", Ref 10)
         ; Add (Entity_id 12, "block/parent", Ref 10)
         ; Add (Entity_id 12, "block/order", String "a1")
         ; Add (Entity_id 12, "block/created-at", Int (now - day))
         ; Add (Entity_id 12, "block/updated-at", Int (now - day))
         ; Add (Entity_id 12, "block/tags", Ref 2)
         ; Add (Entity_id 12, "logseq.property.fsrs/due", Instant now)
         ; Add (Entity_id 13, "block/uuid", Uuid "future-card")
         ; Add (Entity_id 13, "block/title", String "Future card")
         ; Add (Entity_id 13, "block/page", Ref 10)
         ; Add (Entity_id 13, "block/parent", Ref 10)
         ; Add (Entity_id 13, "block/order", String "a2")
         ; Add (Entity_id 13, "block/created-at", Int (now - day))
         ; Add (Entity_id 13, "block/updated-at", Int (now - day))
         ; Add (Entity_id 13, "block/tags", Ref 1)
         ; Add (Entity_id 13, "logseq.property.fsrs/due", Instant (now + day))
         ; Add (Entity_id 13, "logseq.property.fsrs/state", future_state)
         ; Add (Entity_id 14, "block/uuid", Uuid "card-answer")
         ; Add (Entity_id 14, "block/title", String "The answer")
         ; Add (Entity_id 14, "block/page", Ref 10)
         ; Add (Entity_id 14, "block/parent", Ref 11)
         ; Add (Entity_id 14, "block/order", String "a1")
         ; Add (Entity_id 14, "block/created-at", Int now)
         ; Add (Entity_id 14, "block/updated-at", Int now)
         ]
  in
  let due = Flashcards.due_cards db ~now in
  let uuids = List.map (fun card -> card.Flashcards.block.Logseq_chat_model.uuid) due in
  assert_bool "new cards without FSRS properties are immediately due" (List.mem "new-card" uuids);
  assert_bool "Card subclasses participate in reviews" (List.mem "due-subclass" uuids);
  assert_bool "future cards are excluded" (not (List.mem "future-card" uuids));
  assert_bool "a card includes its child answer blocks"
    (match List.find_opt (fun card -> String.equal card.Flashcards.block.uuid "new-card") due with
     | Some card -> List.map (fun block -> block.Logseq_chat_model.title) card.children = [ "The answer" ]
     | None -> false);
  assert_int "only due cards are returned" 2 (List.length due)
;;
