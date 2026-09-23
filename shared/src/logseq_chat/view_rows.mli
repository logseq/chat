type retained_row = {
  render_key : string;
  value : Model.outline_row;
  is_editing : bool;
  editing_title : string;
  editing_caret : int;
}
val make_retained_outline_row :
  Model.chat_model -> Model.outline_row -> retained_row
val retained_outliner_rows : Model.chat_model -> retained_row list
val first_journal_section_visible_ : Model.chat_model -> bool
val first_journal_section_identifier : Model.chat_model -> string
val first_journal_retained_rows : Model.chat_model -> retained_row list
val remaining_retained_outliner_rows : Model.chat_model -> retained_row list
val retained_row_value : retained_row -> Model.outline_row
val retained_row_identifier : retained_row -> string
val retained_row_editing_ : retained_row -> bool
val retained_row_editing_title : retained_row -> string
val retained_row_editing_caret : retained_row -> int
