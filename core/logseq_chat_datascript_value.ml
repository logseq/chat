module LG = Logseq_chat_lg_core_native

let built_in_ref_attrs =
  [ "block/parent"
  ; "block/page"
  ; "block/refs"
  ; "block/tags"
  ; "block/link"
  ; "block/alias"
  ; "block/closed-value-property"
  ]
;;

let value_type_is_ref = LG.logseq_chat_datascript_value_value_type_is_ref
let entity_declares_ref = LG.logseq_chat_datascript_value_entity_declares_ref
let is_ref_attr = LG.logseq_chat_datascript_value_is_ref_attr
let ref_eid = LG.logseq_chat_datascript_value_ref_eid
let optional_ref_eid = LG.logseq_chat_datascript_value_optional_ref_eid
let datoms_by_ref = LG.logseq_chat_datascript_value_datoms_by_ref
