let is_uuid value = Logseq_chat_lg_core_native.logseq_chat_ref_text_is_uuid_ value

let plain_tag_label value =
  Logseq_chat_lg_core_native.logseq_chat_ref_text_plain_tag_label_ value
;;

let to_text ~tag_title ~ref_title title =
  Logseq_chat_lg_core_native.logseq_chat_ref_text_to_text tag_title ref_title title
;;

let to_ids ~resolve_ref ~resolve_tag title =
  Logseq_chat_lg_core_native.logseq_chat_ref_text_to_ids resolve_ref resolve_tag title
;;
