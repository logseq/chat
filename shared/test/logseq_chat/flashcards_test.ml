open Test_util

module Ds = Datascript

let now = 1776000000000

let day = 86400000

let again_starts_learning_with_the_upstream_fsrs_parameters () =
  let card = Flashcards.repeat now (Flashcards.new_card now) Flashcards.Again in
  check_eq Flashcards.Learning card.state;
  check_eq 1 card.reps;
  check_eq 1 card.lapses;
  check_eq (now + 60000) card.due;
  check (Float.abs (7.2102 -. card.difficulty) <= 0.000001);
  check (Float.abs (0.4072 -. card.stability) <= 0.000001)

let easy_starts_review_with_the_upstream_initial_interval () =
  let card = Flashcards.repeat now (Flashcards.new_card now) Flashcards.Easy in
  check_eq Flashcards.Review card.state;
  check_eq 0 card.lapses;
  check_eq 15 card.scheduled_days;
  check_eq (now + (15 * day)) card.due

let fsrs_state_round_trips_through_the_logseq_property_map () =
  let original =
    { Flashcards.due = now - day;
      stability = 4.2;
      difficulty = 5.1;
      elapsed_days = 2;
      scheduled_days = 2;
      reps = 7;
      lapses = 1;
      state = Flashcards.Review;
      last_repeat = now - (2 * day);
      last_rating = Some Flashcards.Good;
    }
  in
  let decoded =
    Flashcards.card_of_values (now - (10 * day)) (Some original.due)
      (Some (Flashcards.state_value original))
  in
  let repeated = Flashcards.repeat now decoded Flashcards.Good in
  check_eq original decoded;
  check_eq Flashcards.Review repeated.state;
  check_eq 8 repeated.reps;
  check (repeated.due > now);
  check_eq (Some Flashcards.Good) repeated.last_rating

let review_sequence_matches_the_upstream_fsrs_v5_reference () =
  let started_at = 1689432134706 in
  let ratings =
    [
      Flashcards.Good; Flashcards.Good; Flashcards.Good; Flashcards.Good;
      Flashcards.Good; Flashcards.Good; Flashcards.Again; Flashcards.Again;
      Flashcards.Good; Flashcards.Good; Flashcards.Good; Flashcards.Good;
      Flashcards.Good;
    ]
  in
  let intervals, card, _ =
    List.fold_left
      (fun (intervals, card, now) rating ->
         let next = Flashcards.repeat now card rating in
         (intervals @ [ next.scheduled_days ], next, next.due))
      ([], Flashcards.new_card started_at, started_at)
      ratings
  in
  check_eq [ 0; 4; 15; 48; 136; 351; 0; 0; 7; 13; 24; 43; 77 ] intervals;
  check_eq 13 card.reps;
  check_eq 2 card.lapses;
  check_eq Flashcards.Review card.state

let one =
  { Storage_codec.default_schema_attr with Datascript.indexed = true }

let schema =
  List.concat
    [
      [
        ( "db/ident"
        , { one with
            Datascript.unique = Some Datascript.Identity;
            value_type = Some Datascript.KeywordType;
          } );
        ( "block/uuid"
        , { one with
            Datascript.unique = Some Datascript.Identity;
            value_type = Some Datascript.UuidType;
          } );
        ("logseq.property.fsrs/due", one);
        ("logseq.property.fsrs/state", one);
      ];
      List.map
        (fun name -> (name, { one with Datascript.value_type = Some Datascript.StringType }))
        [ "block/title"; "block/name"; "block/order" ];
      List.map
        (fun name -> (name, { one with Datascript.value_type = Some Datascript.RefType }))
        [ "block/page"; "block/parent" ];
      List.map
        (fun name -> (name, { one with Datascript.value_type = Some Datascript.NumberType }))
        [ "block/created-at"; "block/updated-at" ];
      List.map
        (fun name ->
           ( name
           , { one with
               Datascript.value_type = Some Datascript.RefType;
               cardinality = Datascript.Many;
             } ))
        [ "block/tags"; "logseq.property.class/extends" ];
    ]

let add eid attr value =
  Ds.Add (Ds.Entity_id eid, attr, value)

let block_tx eid uuid title parent order created_at =
  [
    add eid "block/uuid" (Ds.Uuid uuid);
    add eid "block/title" (Ds.String title);
    add eid "block/page" (Ds.Ref 10);
    add eid "block/parent" (Ds.Ref parent);
    add eid "block/order" (Ds.String order);
    add eid "block/created-at" (Ds.Int created_at);
    add eid "block/updated-at" (Ds.Int created_at);
  ]

let ordered_uuids db =
  List.map (fun (card : Flashcards.due_card) -> card.block.Cache_model.uuid)
    (Flashcards.due_cards db now)

let due_cards_include_subclasses_answers_and_stable_due_ordering () =
  let future_state =
    Flashcards.state_value
      { (Flashcards.new_card (now - day)) with Flashcards.due = now + day }
  in
  let tx =
    List.concat
      [
        [
          add 1 "db/ident" (Ds.Keyword "logseq.class/Card");
          add 2 "db/ident" (Ds.Keyword "user.class/LanguageCard");
          add 2 "logseq.property.class/extends" (Ds.Ref 1);
          add 10 "block/uuid" (Ds.Uuid "page");
          add 10 "block/title" (Ds.String "Page");
          add 10 "block/name" (Ds.String "page");
        ];
        block_tx 11 "new-card" "New card" 10 "a0" (now - day);
        block_tx 12 "due-subclass" "Due subclass card" 10 "a1" (now - day);
        block_tx 13 "future-card" "Future card" 10 "a2" (now - day);
        block_tx 14 "card-answer" "The answer" 11 "a1" now;
        [
          add 11 "block/tags" (Ds.Ref 1);
          add 12 "block/tags" (Ds.Ref 2);
          add 12 "logseq.property.fsrs/due" (Ds.Instant (Int64.of_int now));
          add 13 "block/tags" (Ds.Ref 1);
          add 13 "logseq.property.fsrs/due" (Ds.Instant (Int64.of_int (now + day)));
          add 13 "logseq.property.fsrs/state" future_state;
        ];
      ]
  in
  let db = Ds.db_with tx (Ds.empty_db ~schema ()) in
  let due = Flashcards.due_cards db now in
  let uuids = ordered_uuids db in
  check (List.mem "new-card" uuids);
  check (List.mem "due-subclass" uuids);
  check (not (List.mem "future-card" uuids));
  check_eq 2 (List.length due);
  check_eq (Some [ "The answer" ])
    (List.find_map
       (fun (card : Flashcards.due_card) ->
          if card.block.Cache_model.uuid = "new-card" then
            Some
              (List.map
                 (fun (child : Cache_model.block) -> child.Cache_model.title)
                 card.children)
          else None)
       due);
  let tied =
    Ds.db_with
      [
        add 11 "logseq.property.fsrs/due" (Ds.Instant (Int64.of_int now));
        add 11 "logseq.property.fsrs/state" future_state;
        add 12 "logseq.property.fsrs/state" future_state;
      ]
      db
  in
  let earlier =
    Ds.db_with
      [ add 11 "logseq.property.fsrs/due" (Ds.Instant (Int64.of_int (now - 1))) ]
      tied
  in
  check_eq [ "due-subclass"; "new-card" ] (ordered_uuids tied);
  check_eq [ "new-card"; "due-subclass" ] (ordered_uuids earlier)

let cases =
  [
    case "again starts learning with the upstream fsrs parameters"
      again_starts_learning_with_the_upstream_fsrs_parameters;
    case "easy starts review with the upstream initial interval"
      easy_starts_review_with_the_upstream_initial_interval;
    case "fsrs state round trips through the logseq property map"
      fsrs_state_round_trips_through_the_logseq_property_map;
    case "review sequence matches the upstream fsrs v5 reference"
      review_sequence_matches_the_upstream_fsrs_v5_reference;
    case "due cards include subclasses answers and stable due ordering"
      due_cards_include_subclasses_answers_and_stable_due_ordering;
  ]
