open Logseq_chat_lg_core_native

let fail label message = failwith (label ^ ": " ^ message)
let assert_bool label value = if not value then fail label "expected true"
let plan ~find ~children command = logseq_chat_outliner_plan find children command

let block ?(parent_uuid = "page") ?(page_uuid = "page") ?(order = "a0") uuid title =
  { uuid; title; page_uuid; parent_uuid; order }
;;

let () =
  let source = block "source" "hello world" in
  let command =
    Split
      { source_uuid = "source"
      ; expected_title = "hello world"
      ; before = "hello"
      ; after = " world"
      ; new_uuid = "new"
      ; new_order = "a1"
      ; created_at = 42
      }
  in
  assert_bool "split plans one atomic title update and sibling insert"
    (plan ~find:(fun uuid -> if String.equal uuid "source" then Some source else None)
       ~children:(fun _ -> []) command
     = Ok
         [ Set_title { uuid = "source"; title = "hello" }
         ; Insert
             { insert_block = block ~order:"a1" "new" " world"
             ; created_at = 42
             }
         ])
;;

let () =
  let source = block "source" "old title" in
  let command =
    Split
      { source_uuid = "source"
      ; expected_title = "old title"
      ; before = "edited"
      ; after = " title"
      ; new_uuid = "new"
      ; new_order = "a1"
      ; created_at = 42
      }
  in
  assert_bool "split can atomically save an edited title while checking the old title"
    (Result.is_ok
       (plan ~find:(fun uuid -> if String.equal uuid "source" then Some source else None)
          ~children:(fun _ -> []) command))
;;

let () =
  let source = block "source" "hello" in
  let inserted = block ~order:"a1" "new" " world" in
  let command =
    Split
      { source_uuid = "source"
      ; expected_title = "hello world"
      ; before = "hello"
      ; after = " world"
      ; new_uuid = "new"
      ; new_order = "a1"
      ; created_at = 42
      }
  in
  assert_bool "an already committed split is an idempotent retry"
    (plan
       ~find:(function
         | "source" -> Some source
         | "new" -> Some inserted
         | _ -> None)
       ~children:(fun _ -> [])
       command
     = Ok [])
;;

let () =
  let source = block ~parent_uuid:"parent" "source" " world" in
  let previous = block ~parent_uuid:"parent" "previous" "hello" in
  let child = block ~parent_uuid:"source" "child" "nested" in
  let command : command =
    Merge_backward
      { source_uuid = "source"
      ; expected_source_title = " world"
      ; source_title = " world"
      ; previous_uuid = "previous"
      ; expected_previous_title = "hello"
      ; merged_title = None
      }
  in
  assert_bool "merge plans title child reparent and source delete atomically"
    (plan
       ~find:(function
         | "source" -> Some source
         | "previous" -> Some previous
         | "child" -> Some child
         | _ -> None)
       ~children:(fun uuid -> if String.equal uuid "source" then [ child ] else [])
       command
     = Ok
         [ Set_title { uuid = "previous"; title = "hello world" }
         ; Reparent { uuid = "child"; page_uuid = "page"; parent_uuid = "previous" }
         ; Delete { uuid = "source" }
         ])
;;

let () =
  let source = block "source" "local" in
  let invalid_split =
    Split
      { source_uuid = "source"
      ; expected_title = "remote"
      ; before = "re"
      ; after = "mote"
      ; new_uuid = "new"
      ; new_order = "a1"
      ; created_at = 42
      }
  in
  assert_bool "split conflicts when source title changed"
    (Result.is_error
       (plan ~find:(fun _ -> Some source) ~children:(fun _ -> []) invalid_split));
  let previous = block ~page_uuid:"other" "previous" "before" in
  let invalid_merge : command =
    Merge_backward
      { source_uuid = "source"
      ; expected_source_title = "local"
      ; source_title = "local"
      ; previous_uuid = "previous"
      ; expected_previous_title = "before"
      ; merged_title = None
      }
  in
  assert_bool "merge rejects cross-page targets"
    (Result.is_error
       (plan
          ~find:(function "source" -> Some source | _ -> Some previous)
          ~children:(fun _ -> []) invalid_merge))
;;

let split_request ?(source_uuid = "source") ?(expected_title = "title") ?(new_uuid = "new") () =
  Split
    { source_uuid
    ; expected_title
    ; before = "before"
    ; after = "after"
    ; new_uuid
    ; new_order = "a1"
    ; created_at = 42
    }
;;

let merge_request
    ?(source_uuid = "source")
    ?(expected_source_title = "source title")
    ?(previous_uuid = "previous")
    ?(expected_previous_title = "previous title")
    ?merged_title
    ()
  : command =
  Merge_backward
    { source_uuid
    ; expected_source_title
    ; source_title = "source title"
    ; previous_uuid
    ; expected_previous_title
    ; merged_title
    }
;;

let assert_error label expected result =
  assert_bool label (result = Error expected)
;;

let () =
  let source = block "source" "title" in
  let find_source uuid = if String.equal uuid "source" then Some source else None in
  assert_error "split rejects a missing source" "split source no longer exists"
    (plan ~find:(fun _ -> None) ~children:(fun _ -> []) (split_request ()));
  assert_error "split rejects the same UUID" "split requires a distinct new block UUID"
    (plan ~find:find_source ~children:(fun _ -> []) (split_request ~new_uuid:"source" ()));
  assert_error "split rejects a blank UUID" "split requires a distinct new block UUID"
    (plan ~find:find_source ~children:(fun _ -> []) (split_request ~new_uuid:"  " ()));
  assert_error "split rejects an existing UUID" "split block UUID already exists"
    (plan ~find:(fun _ -> Some source) ~children:(fun _ -> []) (split_request ()))
;;

let () =
  let source = block "source" "source title" in
  let previous = block "previous" "previous title" in
  let find = function
    | "source" -> Some source
    | "previous" -> Some previous
    | _ -> None
  in
  assert_error "merge rejects a missing source" "merge source no longer exists"
    (plan ~find:(fun uuid -> if String.equal uuid "previous" then Some previous else None)
       ~children:(fun _ -> []) (merge_request ()));
  assert_error "merge rejects a missing target" "merge target no longer exists"
    (plan ~find:(fun uuid -> if String.equal uuid "source" then Some source else None)
       ~children:(fun _ -> []) (merge_request ()));
  assert_error "merge rejects the same block" "merge source and target must be different blocks"
    (plan ~find ~children:(fun _ -> []) (merge_request ~previous_uuid:"source" ()));
  assert_error "merge rejects a changed source" "merge source title changed on the server"
    (plan ~find ~children:(fun _ -> [])
       (merge_request ~expected_source_title:"stale" ()));
  assert_error "merge rejects a changed target" "merge target title changed on the server"
    (plan ~find ~children:(fun _ -> [])
       (merge_request ~expected_previous_title:"stale" ()));
  assert_error "merge rejects a child target" "merge target cannot be a child of the source"
    (plan ~find ~children:(fun _ -> [ previous ]) (merge_request ()));
  assert_bool "merge accepts an explicit merged title"
    (plan ~find ~children:(fun _ -> []) (merge_request ~merged_title:"explicit" ())
     = Ok
         [ Set_title { uuid = "previous"; title = "explicit" }
         ; Delete { uuid = "source" }
         ])
;;
