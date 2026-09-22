type retained_row =
  { render_key : string
  ; value : Model.outline_row
  ; is_editing : bool
  ; editing_title : string
  ; editing_caret : int
  }

let make_retained_outline_row (current : Model.chat_model)
    (row : Model.outline_row) =
  match current.outliner_editing with
  | Some editing ->
    if editing.editing_uuid = row.row_uuid then
      {
        render_key = "active-outliner-editor";
        value = row;
        is_editing = true;
        editing_title = editing.editing_title;
        editing_caret = editing.caret_utf16_offset;
      }
    else
      {
        render_key = row.row_uuid;
        value = row;
        is_editing = false;
        editing_title = "";
        editing_caret = 0;
      }
  | None ->
    {
      render_key = row.row_uuid;
      value = row;
      is_editing = false;
      editing_title = "";
      editing_caret = 0;
    }

let retained_outliner_rows (current : Model.chat_model) =
  List.map (fun row -> make_retained_outline_row current row)
    current.outliner_rows

let first_journal_section_visible_ (current : Model.chat_model) =
  View_base.journal_root_visible_ current
  && current.selected_page = None
  && current.outliner_section_markers <> []
  && (List.hd current.outliner_section_markers).start_index = 0

let first_journal_section_identifier (current : Model.chat_model) =
  if first_journal_section_visible_ current then
    "journal.section."
    ^ (List.hd current.outliner_section_markers).page_id
  else "journal.section"

let first_journal_retained_rows (current : Model.chat_model) =
  if first_journal_section_visible_ current then begin
    let section = List.hd current.outliner_section_markers in
    List.map
      (fun row -> make_retained_outline_row current row)
      (Model.sub_list section.start_index section.end_index
         current.outliner_rows)
  end
  else []

let remaining_retained_outliner_rows (current : Model.chat_model) =
  if first_journal_section_visible_ current then begin
    let section = List.hd current.outliner_section_markers in
    List.map
      (fun row -> make_retained_outline_row current row)
      (Model.sub_list section.end_index (List.length current.outliner_rows)
         current.outliner_rows)
  end
  else retained_outliner_rows current

let retained_row_value (retained : retained_row) = retained.value
let retained_row_identifier (retained : retained_row) = retained.render_key
let retained_row_editing_ (retained : retained_row) = retained.is_editing
let retained_row_editing_title (retained : retained_row) =
  retained.editing_title

let retained_row_editing_caret (retained : retained_row) =
  retained.editing_caret
