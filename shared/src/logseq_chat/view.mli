type retained_outline_row

val outliner_editor_schema : unit -> extension_component_schema

val outliner_block_content_schema : unit -> extension_component_schema

val native_navigation_stack_schema : unit -> extension_component_schema

val native_search_presentation_schema : unit -> extension_component_schema

val native_overflow_menu_schema : unit -> extension_component_schema

val liquid_glass_schema : unit -> extension_component_schema

val extension_registry : unit -> extension_registry

val string_wire_value : string -> wire_value

val int_wire_value : int -> wire_value

val extension_string : (string, wire_value) map -> string -> string

val extension_int : (string, wire_value) map -> string -> int

val navigation_path_depth : navigation_route Rrbvec.t -> int

val handle_native_navigation_event : event -> (chat_action -> bool) -> bool

val handle_native_search_event : event -> (chat_action -> bool) -> bool

val handle_native_overflow_menu_event : event -> (chat_action -> bool) -> bool

val handle_outliner_editor_event : event -> string signal -> (chat_action -> bool) -> bool

val outliner_editor_view :
  ui_context -> string signal -> string signal -> int signal -> (chat_action -> bool) ->
  int

val optional_string : string option -> string

val outliner_row_youtube_target : outline_row -> string

val outliner_row_asset_type : outline_row -> string

val outliner_row_local_path : outline_row -> string

val outliner_row_completed_ : outline_row -> bool

val outliner_row_has_status_ : outline_row -> bool

val outliner_row_status_title : outline_row -> string

val outliner_editor_task_label : chat_model -> string

val outliner_row_has_tags_ : outline_row -> bool

val outliner_row_journal_ : chat_model -> outline_row -> bool

val outliner_row_sync_failed_ : outline_row -> bool

val outliner_row_list_item_press_enabled_ : host_kind -> outline_row -> bool

val outliner_tag_identifier : sidebar_page -> string

val outliner_tag_title : sidebar_page -> string

val outliner_tag : ui_context -> sidebar_page signal -> (chat_action -> bool) -> int

val request_node_action : chat_model -> string -> chat_action

val handle_outliner_block_content_event :
  event -> chat_model signal -> (chat_action -> bool) -> bool

val graph_label : chat_model -> string

val sync_label : chat_model -> string

val sync_indicator_label : chat_model -> string

val sync_accessibility_identifier : chat_model -> string

val sync_indicator_foreground : chat_model -> string

val sync_connection_label : chat_model -> string

val sync_pending_label : chat_model -> string

val sync_cursor_label : chat_model -> string

val active_page_actions_visible_ : chat_model -> bool

val connection_settings_visible_ : chat_model -> bool

val active_page_favorite_label : chat_model -> string

val page_deletion_pending_ : chat_model -> bool

val sidebar_page_identifier : sidebar_page -> string

val sidebar_page_title : sidebar_page -> string

val sidebar_graph_identifier : graph -> string

val graph_title : graph -> string

val sidebar_graph_selected_ : chat_model -> graph -> bool

val sidebar_graph_disabled_ : graph -> bool

val journals_sidebar_selected_ : chat_model -> bool

val flashcards_sidebar_selected_ : chat_model -> bool

val graphs_sidebar_selected_ : chat_model -> bool

val sidebar_page_selected_ : chat_model -> sidebar_page -> bool

val favorites_empty_ : chat_model -> bool

val recent_pages_empty_ : chat_model -> bool

val sidebar_favorites : chat_model -> sidebar_page Rrbvec.t

val sidebar_recent_pages : chat_model -> sidebar_page Rrbvec.t

val model_task_statuses : chat_model -> task_status Rrbvec.t

val model_outliner_autocomplete_candidates :
  chat_model -> outliner_autocomplete_candidate Rrbvec.t

val model_composer_assets : chat_model -> composer_asset Rrbvec.t

val model_language_choices : chat_model -> settings_language_choice Rrbvec.t

val model_community_links : chat_model -> settings_community_link Rrbvec.t

val model_graph_menu_open_ : chat_model -> bool

val model_task_status_picker_open_ : chat_model -> bool

val model_new_graph_name : chat_model -> string

val model_new_graph_encrypted_ : chat_model -> bool

val model_graph_password : chat_model -> string

val model_graphs : chat_model -> graph Rrbvec.t

val model_settings_language_menu_open_ : chat_model -> bool

val model_settings_appearance_menu_open_ : chat_model -> bool

val model_search_loading_ : chat_model -> bool

val model_search_query : chat_model -> string

val model_search_open_ : chat_model -> bool

val model_settings_open_ : chat_model -> bool

val model_create_graph_open_ : chat_model -> bool

val model_graph_password_open_ : chat_model -> bool

val model_sync_details_open_ : chat_model -> bool

val sidebar_tab_visible_ : chat_model -> string -> bool

val flashcards_tab_visible_ : chat_model -> bool

val graphs_tab_visible_ : chat_model -> bool

val sidebar_page_row :
  ui_context -> chat_model signal -> sidebar_page signal -> (chat_action -> bool) -> int

val sidebar_graph_menu_item :
  ui_context -> chat_model signal -> graph signal -> (chat_action -> bool) -> int

val sidebar_section_heading : ui_context -> string -> string -> int

val sidebar_view : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val composer_collapsed_ : chat_model -> bool

val composer_expanded_ : chat_model -> bool

val composer_draft : chat_model -> string

val composer_autofocus_ : chat_model -> bool

val composer_send_disabled_ : chat_model -> bool

val task_status_identifier : task_status -> string

val task_status_title : task_status -> string

val task_status_style : task_status -> string

val task_status_icon_name : task_status -> string

val task_status_foreground : task_status -> string

val task_status_selected_ : chat_model -> bool

val search_result_identifier : search_hit -> string

val search_result_title : search_hit -> string

val search_result_context_present_ : search_hit -> bool

val search_result_status : chat_model -> string

val search_result_breadcrumb : search_hit -> string

val page_search_results : chat_model -> search_hit Rrbvec.t

val block_search_results : chat_model -> search_hit Rrbvec.t

val page_search_results_present_ : chat_model -> bool

val block_search_results_present_ : chat_model -> bool

val search_empty_state_present_ : chat_model -> bool

val search_results_present_ : chat_model -> bool

val search_empty_message : chat_model -> string

val search_result_row : ui_context -> search_hit signal -> (chat_action -> bool) -> int

val outliner_row_identifier : outline_row -> string

val outliner_row_breadcrumbs : outline_row -> sidebar_page Rrbvec.t

val outliner_row_tags : outline_row -> sidebar_page Rrbvec.t

val outliner_row_action_identifier : outline_row -> string

val retained_outliner_rows : chat_model -> retained_outline_row Rrbvec.t

val make_retained_outline_row : chat_model -> outline_row -> retained_outline_row

val retained_row_value : retained_outline_row -> outline_row

val retained_row_identifier : retained_outline_row -> string

val retained_row_editing_ : retained_outline_row -> bool

val retained_row_editing_title : retained_outline_row -> string

val retained_row_editing_caret : retained_outline_row -> int

val outliner_row_title : outline_row -> string

val outliner_row_uuid : outline_row -> string

val outliner_row_indent : outline_row -> int

val outliner_row_has_children : outline_row -> bool

val outliner_row_zoom_label : outline_row -> string

val outliner_row_zoom_identifier : outline_row -> string

val outliner_row_action_label : chat_model -> outline_row -> string

val outliner_row_collapse_label : outline_row -> string

val outliner_row_collapse_glyph : outline_row -> string

val outliner_collapse_icon_name : bool -> string

val outliner_collapse_identifier : outline_row -> string

val outliner_collapse_button : ui_context -> outline_row signal -> (chat_action -> bool) -> int

val outliner_indent_view : ui_context -> int signal -> int

val row_editing_ : chat_model -> outline_row -> bool

val row_not_editing_ : chat_model -> outline_row -> bool

val string_vector_contains_ : string Rrbvec.t -> string -> bool

val row_selected_ : chat_model -> outline_row -> bool

val outliner_selection_active_ : chat_model -> bool

val outliner_selection_inactive_ : chat_model -> bool

val outliner_editor_active_ : chat_model -> bool

val outliner_autocomplete_active_ : chat_model -> bool

val outliner_autocomplete_identifier : outliner_autocomplete_candidate -> string

val outliner_autocomplete_label : outliner_autocomplete_candidate -> string

val node_navigation_active_ : chat_model -> bool

val node_navigation_inactive_ : chat_model -> bool

val journals_destination_ : chat_model -> bool

val flashcards_destination_ : chat_model -> bool

val graphs_destination_ : chat_model -> bool

val journal_route_active_ : chat_model -> bool

val journal_root_visible_ : chat_model -> bool

val journal_home_visible_ : chat_model -> bool

val selected_page_visible_ : chat_model -> bool

val selected_page_models : chat_model -> chat_model Rrbvec.t

val selected_page_model_key : chat_model -> string

val journal_tree_retained_ : chat_model -> bool

val older_journals_visible_ : chat_model -> bool

val journal_section_marker_for :
  journal_section_marker Rrbvec.t -> string -> journal_section_marker option

val outliner_journal_marker : chat_model -> outline_row -> journal_section_marker option

val outliner_journal_heading_visible_ : chat_model -> outline_row -> bool

val outliner_journal_divider_visible_ : chat_model -> outline_row -> bool

val outliner_journal_title : chat_model -> outline_row -> string

val outliner_journal_page_id : chat_model -> outline_row -> string

val outliner_journal_button_identifier : chat_model -> outline_row -> string

val node_screen_visible_ : chat_model -> bool

val primary_sidebar_button_visible_ : chat_model -> bool

val sidebar_drag_disabled_ : chat_model -> bool

val connection_control_visible_ : chat_model -> bool

val search_query_present_ : chat_model -> bool

val bottom_chrome_presentation : chat_model -> string

val bottom_chrome_selection_ : chat_model -> bool

val bottom_chrome_editor_ : chat_model -> bool

val bottom_chrome_expanded_composer_ : chat_model -> bool

val bottom_chrome_capture_and_search_ : chat_model -> bool

val bottom_chrome_occupies_layout_space_ : chat_model -> bool

val active_node_projection : chat_model -> node_projection option

val node_projection_identifier : node_projection -> string

val active_node_uuid : chat_model -> string

val active_node_title : chat_model -> string

val main_title : chat_model -> string

val current_content_active_ : chat_model -> bool

val current_content_is_tag_ : chat_model -> bool

val current_content_is_property_ : chat_model -> bool

val active_node_page_uuid : chat_model -> string

val active_node_related_rows : chat_model -> outline_row Rrbvec.t

val active_node_linked_reference_rows : chat_model -> outline_row Rrbvec.t

val node_related_section_visible_ : chat_model -> bool

val node_tag_section_visible_ : chat_model -> bool

val node_tag_section_empty_ : chat_model -> bool

val node_linked_reference_section_visible_ : chat_model -> bool

val node_can_add_first_block_ : chat_model -> bool

val node_outliner_visible_ : chat_model -> bool

val node_title_visible_ : chat_model -> bool

val main_can_add_first_block_ : chat_model -> bool

val main_related_section_visible_ : chat_model -> bool

val main_tag_section_visible_ : chat_model -> bool

val main_linked_reference_section_visible_ : chat_model -> bool

val outliner_row_has_breadcrumb_ : outline_row -> bool

val outliner_row_breadcrumb : outline_row -> string

val outliner_row_structured_breadcrumb_ : outline_row -> bool

val outliner_row_fallback_breadcrumb_ : outline_row -> bool

val breadcrumb_identifier : sidebar_page -> string

val breadcrumb_title : sidebar_page -> string

val breadcrumb_button :
  ui_context -> sidebar_page signal -> bool -> (chat_action -> bool) -> int

val related_row_breadcrumbs : ui_context -> outline_row signal -> (chat_action -> bool) -> int

val editing_title : chat_model -> string

val editing_caret : chat_model -> int

val outliner_row_main_content :
  ui_context -> chat_model signal -> retained_outline_row signal -> outline_row signal
  -> (chat_action -> bool) -> int

val outliner_row_content :
  ui_context -> chat_model signal -> retained_outline_row signal -> outline_row signal
  -> (chat_action -> bool) -> bool -> int

val outliner_row :
  ui_context -> chat_model signal -> retained_outline_row signal -> outline_row signal
  -> (chat_action -> bool) -> int

val outliner_entry :
  ui_context -> chat_model signal -> retained_outline_row signal -> outline_row signal
  -> (chat_action -> bool) -> int

val outliner_selection_toolbar : ui_context -> (chat_action -> bool) -> int

val outliner_autocomplete_row :
  ui_context -> outliner_autocomplete_candidate signal -> (chat_action -> bool) -> int

val outliner_autocomplete_bar : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val outliner_editor_toolbar : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val node_related_row :
  ui_context -> chat_model signal -> outline_row signal -> (chat_action -> bool) -> int

val node_related_section : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val node_tagged_section : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val node_linked_reference_section :
  ui_context -> chat_model signal -> (chat_action -> bool) -> int

val add_first_block_button : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val node_screen : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val composer_view : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val task_status_row : ui_context -> task_status signal -> (chat_action -> bool) -> int

val task_status_picker_dialog : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val outliner_task_status_option_identifier : task_status -> string

val outliner_task_status_row :
  ui_context -> string -> task_status signal -> (chat_action -> bool) -> int

val first_flashcard : chat_model -> flashcard option

val flashcards_empty_ : chat_model -> bool

val flashcards_present_ : chat_model -> bool

val flashcard_question : chat_model -> string

val flashcard_remaining_label : chat_model -> string

val flashcard_show_cloze_ : chat_model -> bool

val flashcard_show_answer_ : chat_model -> bool

val flashcard_show_ratings_ : chat_model -> bool

val visible_flashcard_answer_rows : chat_model -> flashcard_answer_row Rrbvec.t

val flashcard_answer_identifier : flashcard_answer_row -> string

val flashcard_answer_text : flashcard_answer_row -> string

val flashcard_answer_row : ui_context -> flashcard_answer_row signal -> int

val flashcard_screen : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val graph_identifier : graph -> string

val graph_delete_identifier : graph -> string

val graph_status_identifier : graph -> string

val graph_status_visible_ : graph -> bool

val graph_status_title : graph -> string

val graph_not_ready_ : graph -> bool

val graph_row_disabled_ : chat_model -> graph -> bool

val graph_delete_active_ : chat_model -> graph -> bool

val graph_row_local_ : chat_model -> graph -> bool

val graph_icon_name : bool -> graph -> string

val local_graphs : chat_model -> graph Rrbvec.t

val remote_graphs : chat_model -> graph Rrbvec.t

val local_graphs_empty_ : chat_model -> bool

val remote_graphs_present_ : chat_model -> bool

val new_graph_name_empty_ : chat_model -> bool

val graph_create_disabled_ : chat_model -> bool

val graph_unlock_disabled_ : chat_model -> bool

val empty_graphs_loading_ : chat_model -> bool

val empty_graphs_refreshable_ : chat_model -> bool

val graph_deletion_pending_ : chat_model -> bool

val graph_deletion_message : chat_model -> string

val graph_password_empty_ : chat_model -> bool

val effect_error_present_ : chat_model -> bool

val effect_error_message : chat_model -> string

val graph_unlock_error_present_ : chat_model -> bool

val graph_unlock_error_message : chat_model -> string

val global_effect_error_present_ : chat_model -> bool

val graph_row :
  ui_context -> chat_model signal -> graph signal -> bool -> (chat_action -> bool) ->
  int

val graph_list_row :
  ui_context -> chat_model signal -> graph signal -> bool -> (chat_action -> bool) ->
  int

val graph_create_sheet : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val graph_delete_dialog : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val graph_picker_overflow_menu : ui_context -> (chat_action -> bool) -> int

val graph_picker_error_present_ : chat_model -> bool

val graph_picker_error_reason : chat_model -> string option

val error_separator : string -> int

val graph_picker_error_code : chat_model -> string

val graph_picker_error_message : chat_model -> string

val graph_picker_error_banner : ui_context -> chat_model signal -> int

val graph_password_sheet : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val graphs_screen : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val settings_main_visible_ : chat_model -> bool

val settings_spell_check : chat_model -> bool

val settings_auto_correction : chat_model -> bool

val settings_base_url : chat_model -> string

val settings_base_url_invalid_ : chat_model -> bool

val settings_apply_disabled_ : chat_model -> bool

val settings_version : chat_model -> string

val settings_revision : chat_model -> string

val settings_language_title : chat_model -> string

val settings_appearance_title : chat_model -> string

val settings_tab_title : string -> string

val settings_tabs_summary : chat_model -> string

val settings_language_choice_title : settings_language_choice -> string

val settings_language_choice_identifier : settings_language_choice -> string

val settings_language_choice_radio :
  ui_context -> chat_model signal -> settings_language_choice signal -> (chat_action ->
  bool) -> int

val settings_language_choice_menu_item :
  ui_context -> settings_language_choice signal -> (chat_action -> bool) -> int

val settings_language_control : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val settings_appearance_control :
  ui_context -> chat_model signal -> (chat_action -> bool) -> int

val settings_community_link_title : settings_community_link -> string

val settings_community_link_identifier : settings_community_link -> string

val settings_community_link_needs_separator_ : chat_model -> settings_community_link -> bool

val settings_community_link_row :
  ui_context -> chat_model signal -> settings_community_link signal -> (chat_action ->
  bool) -> int

val settings_tabs_visible_ : chat_model -> bool

val runtime_log_visible_ : chat_model -> bool

val tab_enabled_ : chat_model -> string -> bool

val tab_toggle_label : chat_model -> string -> string

val tab_selection_glyph : chat_model -> string -> string

val tab_selection_icon_name : chat_model -> string -> string

val tab_selection_foreground : chat_model -> string -> string

val tab_disabled_ : chat_model -> string -> bool

val tab_index : chat_model -> string -> int

val tab_movement_visible_ : chat_model -> string -> bool

val settings_flashcards_before_graphs_ : chat_model -> bool

val settings_flashcards_after_graphs_ : chat_model -> bool

val settings_available_tabs_present_ : chat_model -> bool

val tab_move_up_disabled_ : chat_model -> string -> bool

val tab_move_down_disabled_ : chat_model -> string -> bool

val tab_toggle_identifier : string -> string

val tab_up_identifier : string -> string

val tab_down_identifier : string -> string

val runtime_log_level : runtime_log_record -> string

val runtime_log_timestamp : runtime_log_record -> string

val runtime_log_message : runtime_log_record -> string

val runtime_log_error_ : runtime_log_record -> bool

val runtime_log_empty_ : chat_model -> bool

val runtime_log_records : chat_model -> runtime_log_record Rrbvec.t

val runtime_log_record_identifier : runtime_log_record -> string

val runtime_log_errors_label : chat_model -> string

val runtime_log_order_label : chat_model -> string

val runtime_log_source_label : chat_model -> string

val runtime_log_row : ui_context -> runtime_log_record signal -> int

val settings_tab_row :
  ui_context -> chat_model signal -> string -> string -> (chat_action -> bool) -> int

val settings_tabs_screen : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val runtime_log_toolbar : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val runtime_log_screen : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val settings_screen : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val settings_main_sheet : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val settings_tabs_sheet : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val runtime_log_sheet : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val settings_sheet : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val page_delete_dialog : ui_context -> (chat_action -> bool) -> int

val sync_error_present_ : chat_model -> bool

val sync_error_message : chat_model -> string

val sync_status_sheet : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val authentication_screen_visible_ : chat_model -> bool

val graph_picker_screen_visible_ : chat_model -> bool

val graph_picker_hidden_ : chat_model -> bool

val drawer_selected_ : chat_model -> bool

val drawer_disabled_ : chat_model -> bool

val authentication_signing_in_ : chat_model -> bool

val authentication_error_present_ : chat_model -> bool

val authentication_error_message : chat_model -> string

val authentication_screen : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val chat_view : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val chat_main_view : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val selected_page_present_ : chat_model -> bool

val selected_page_absent_ : chat_model -> bool

val selected_page_content_title_visible_ : chat_model -> bool

val selected_page_title : chat_model -> string

val root_outliner_view :
  ui_context -> chat_model signal -> bool signal -> (chat_action -> bool) -> int

val retained_journal_pane : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val journal_tree_panes : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val main_bottom_chrome : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val main_header_leading : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val main_header_title : ui_context -> chat_model signal -> int

val main_header_sync : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val active_overflow_menu : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val main_header_connection : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val search_screen : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val journal_navigation_model : chat_model -> chat_model

val node_route_model : chat_model -> node_projection -> chat_model

val app_navigation_depth : chat_model -> int

val search_navigation_depth : chat_model -> int

val search_node_routes : chat_model -> node_projection Rrbvec.t

val active_route_only : node_projection Rrbvec.t -> node_projection Rrbvec.t

val active_app_node_routes : chat_model -> node_projection Rrbvec.t

val active_search_node_routes : chat_model -> node_projection Rrbvec.t

val flutter_app_root_visible_ : chat_model -> bool

val flutter_search_root_visible_ : chat_model -> bool

val native_node_screen :
  ui_context -> chat_model signal -> node_projection signal -> (chat_action -> bool) ->
  int

val native_search_view : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val native_navigation_view : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val composer_asset_schema : unit -> extension_component_schema

val composer_asset_preview : ui_context -> composer_asset signal -> int

val composer_assets_present_ : chat_model -> bool

val composer_asset_title : composer_asset -> string

val composer_asset_path : composer_asset -> string

val active_node_breadcrumbs : chat_model -> sidebar_page Rrbvec.t

val active_node_has_breadcrumbs_ : chat_model -> bool

val node_breadcrumbs : ui_context -> chat_model signal -> (chat_action -> bool) -> int

val node_breadcrumb_button :
  ui_context -> chat_model signal -> sidebar_page signal -> (chat_action -> bool) -> int

val composer_asset_view : ui_context -> composer_asset signal -> (chat_action -> bool) -> int

val composer_asset_identifier : composer_asset -> string
