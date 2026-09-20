type sync_state =
  | OfflineState
  | SyncingState
  | SyncedState
  | FailedState of string

type navigation_route =
  | NodeRoute of string

type primary_destination =
  | JournalsDestination
  | FlashcardsDestination
  | GraphsDestination

type composer_asset = {
  uuid : string;
  title : string;
  local_path : string;
  payload : string;
}

type ui_session = {
  graph_id : string option;
  destination : primary_destination;
  draft : string;
  assets : composer_asset Rrbvec.t;
  composer_expanded : bool;
  search_open : bool;
  query : string;
  app_path : navigation_route Rrbvec.t;
  search_path : navigation_route Rrbvec.t;
  selected_page_id : string option;
  settings_open : bool;
}

type sidebar_page = {
  uuid : string;
  title : string;
}

type graph = {
  id : string;
  name : string;
  is_encrypted : bool;
  is_ready : bool;
}

type task_status = {
  uuid : string;
  ident : string option;
  title : string;
  icon_type : string option;
  icon_id : string option;
  icon_color : string option;
}

type settings_projection = {
  appearance : string;
  language : string;
  spell_check : bool;
  auto_correction : bool;
  sidebar_tabs : string Rrbvec.t;
  base_url : string;
  version : string;
  revision : string;
}

type settings_language_choice = {
  id : string;
  title : string;
}

type settings_community_link = {
  id : string;
  title : string;
  url : string;
}

type runtime_log_record = {
  id : string;
  level : string;
  source : string;
  timestamp : string;
  message : string;
}

type flashcard_answer_row = {
  uuid : string;
  index : int;
  text : string;
}

type flashcard = {
  uuid : string;
  question_hidden : string;
  question_revealed : string;
  answer_rows : flashcard_answer_row Rrbvec.t;
  has_cloze : bool;
}

type search_hit = {
  uuid : string;
  title : string;
  breadcrumb : string;
  breadcrumbs : sidebar_page Rrbvec.t;
  is_page : bool;
}

type outline_row = {
  uuid : string;
  title : string;
  markup_json : string;
  youtube_target_url : string option;
  breadcrumb : string;
  breadcrumbs : sidebar_page Rrbvec.t;
  opens_as_page : bool;
  depth : int;
  has_children : bool;
  is_collapsed : bool;
  is_asset : bool;
  asset_type : string option;
  local_path : string option;
  status : task_status option;
  tags : sidebar_page Rrbvec.t;
  sync_status : string option;
  page_id : string;
  journal_title : string option;
  journal_day : int option;
}

type sidebar_projection = {
  favorites : sidebar_page Rrbvec.t;
  recent_pages : sidebar_page Rrbvec.t;
  selected_page : sidebar_page option;
  selected_page_is_tag : bool;
  selected_page_is_property : bool;
  related_rows : outline_row Rrbvec.t;
  linked_reference_rows : outline_row Rrbvec.t;
}

type journal_section_marker = {
  block_id : string;
  page_id : string;
  title : string;
  has_divider : bool;
  start_index : int;
  end_index : int;
}

type outliner_editing = {
  uuid : string;
  title : string;
  caret_utf16_offset : int;
}

type outliner_autocomplete_kind =
  | NodeAutocomplete
  | TagAutocomplete
  | PropertyAutocomplete

type outliner_autocomplete = {
  kind : outliner_autocomplete_kind;
  query : string;
}

type outliner_autocomplete_candidate = {
  index : int;
  label : string;
  value : string;
}

type node_projection = {
  uuid : string;
  page_uuid : string;
  title : string;
  is_tag : bool;
  is_property : bool;
  outliner_rows : outline_row Rrbvec.t;
  related_rows : outline_row Rrbvec.t;
  linked_reference_rows : outline_row Rrbvec.t;
  outliner_editing : outliner_editing option;
  outliner_autocomplete : outliner_autocomplete option;
  outliner_autocomplete_candidates : outliner_autocomplete_candidate Rrbvec.t;
  outliner_selected_block_ids : string Rrbvec.t;
}

type outline_row_splice = {
  start : int option;
  after_block_id : string option;
  before_block_id : string option;
  delete_count : int;
  rows : outline_row Rrbvec.t;
}

type core_projection = {
  graph_name : string option;
  selected_graph_id : string option;
  graphs : graph Rrbvec.t;
  is_graph_encrypted : bool;
  is_graph_unlocked : bool;
  sidebar : sidebar_projection;
  task_statuses : task_status Rrbvec.t;
  flashcards : flashcard Rrbvec.t;
  sync_connected : bool;
  applied_server_t : int option;
  has_pending_semantic_operations : bool;
  has_pending_sync_request : bool;
  is_pending_sync_patch : bool;
  is_graph_catalog_patch : bool;
  search_query : string;
  search_results : search_hit Rrbvec.t;
  node_routes : node_projection Rrbvec.t;
  journal_outliner_rows : outline_row Rrbvec.t;
  outliner_editing : outliner_editing option;
  outliner_autocomplete : outliner_autocomplete option;
  outliner_autocomplete_candidates : outliner_autocomplete_candidate Rrbvec.t;
  outliner_selected_block_ids : string Rrbvec.t;
  outliner_rows : outline_row Rrbvec.t;
  has_older_journals : bool;
  is_outliner_patch : bool;
  outliner_row_splices : outline_row_splice Rrbvec.t;
}

type chat_effect =
  | SendCaptureEffect of int * string
  | SendAssetEffect of int * composer_asset
  | SendTaskEffect of int * string * task_status
  | PersistComposerDraftEffect of int * string
  | PersistUISessionEffect of int * ui_session
  | PresentAttachmentEffect of int * string
  | PresentAssetEffect of int * string * string * string
  | PresentPageShareEffect of int * string * string Rrbvec.t
  | SetPageFavoriteEffect of int * string * bool
  | DeletePageEffect of int * string
  | SyncNowEffect of int
  | SetOutlinerTaskStatusEffect of int * string * task_status
  | SearchNodesEffect of int * string
  | TapOutlinerBlockEffect of int * string
  | ChangeOutlinerTextEffect of int * string * string * int
  | ReturnOutlinerEditorEffect of int * string * string * int
  | BackspaceOutlinerEditorEffect of int * string * string * int
  | MoveOutlinerCaretEffect of int * string * int
  | ToggleOutlinerCollapsedEffect of int * string
  | LongPressOutlinerBlockEffect of int * string
  | DropOutlinerBlocksEffect of int * string * string
  | OutlinerToolbarEffect of int * string
  | ChooseOutlinerAutocompleteEffect of int * string
  | CancelOutlinerEditingEffect of int
  | OpenAppNodeEffect of int * string
  | OpenSearchNodeEffect of int * string
  | CloseAppNodeEffect of int * string
  | CloseSearchNodeEffect of int * string
  | AddRootBlockEffect of int * string
  | SelectSidebarPageEffect of int * string
  | ClearSelectedPageEffect of int
  | LoadOlderJournalsEffect of int
  | LoadFlashcardsEffect of int
  | ReviewFlashcardEffect of int * string * string
  | RefreshGraphsEffect of int
  | OpenGraphEffect of int * string
  | UnlockGraphEffect of int * string
  | CreateGraphEffect of int * string * bool
  | DeleteLocalGraphEffect of int * string
  | SaveSettingsEffect of int * settings_projection
  | ExportGraphDatabaseEffect of int
  | OpenExternalURLEffect of int * string
  | RefreshRuntimeLogEffect of int * string * bool * bool
  | CopyRuntimeLogEffect of int * runtime_log_record Rrbvec.t
  | SignInEffect of int
  | SignOutEffect of int

type chat_model = {
  selected_graph : string option;
  selected_graph_id : string option;
  graphs : graph Rrbvec.t;
  local_graph_ids : string Rrbvec.t;
  is_graph_encrypted : bool;
  is_graph_unlocked : bool;
  graph_loading : bool;
  graph_password_open : bool;
  graph_password : string;
  authentication_state : string;
  authentication_error : string option;
  sync_state : sync_state;
  applied_server_t : int option;
  has_pending_semantic_operations : bool;
  has_pending_sync_request : bool;
  sync_details_open : bool;
  destination : primary_destination;
  sidebar_open : bool;
  graph_menu_open : bool;
  favorites : sidebar_page Rrbvec.t;
  recent_pages : sidebar_page Rrbvec.t;
  selected_page : sidebar_page option;
  selected_page_is_tag : bool;
  selected_page_is_property : bool;
  related_rows : outline_row Rrbvec.t;
  linked_reference_rows : outline_row Rrbvec.t;
  task_statuses : task_status Rrbvec.t;
  selected_task_status : task_status option;
  flashcards : flashcard Rrbvec.t;
  flashcard_cloze_revealed : bool;
  flashcard_answer_revealed : bool;
  create_graph_open : bool;
  new_graph_name : string;
  new_graph_encrypted : bool;
  pending_graph_deletion : graph option;
  pending_page_deletion : sidebar_page option;
  connection_menu_open : bool;
  settings_open : bool;
  settings_tabs_open : bool;
  runtime_log_open : bool;
  appearance : string;
  settings_appearance_menu_open : bool;
  language : string;
  language_choices : settings_language_choice Rrbvec.t;
  settings_language_menu_open : bool;
  community_links : settings_community_link Rrbvec.t;
  spell_check : bool;
  auto_correction : bool;
  sidebar_tabs : string Rrbvec.t;
  base_url : string;
  version : string;
  revision : string;
  runtime_log_source : string;
  runtime_log_errors_only : bool;
  runtime_log_newest_first : bool;
  runtime_log_records : runtime_log_record Rrbvec.t;
  search_open : bool;
  search_query : string;
  search_results : search_hit Rrbvec.t;
  search_loading : bool;
  node_routes : node_projection Rrbvec.t;
  journal_outliner_rows : outline_row Rrbvec.t;
  outliner_rows : outline_row Rrbvec.t;
  outliner_selected_block_ids : string Rrbvec.t;
  outliner_editing : outliner_editing option;
  outliner_autocomplete : outliner_autocomplete option;
  outliner_autocomplete_candidates : outliner_autocomplete_candidate Rrbvec.t;
  outliner_section_markers : journal_section_marker Rrbvec.t;
  has_older_journals : bool;
  composer_expanded : bool;
  composer_draft : string;
  composer_assets : composer_asset Rrbvec.t;
  composer_autofocus : bool;
  pending_effects : chat_effect Rrbvec.t;
  in_flight_effects : chat_effect Rrbvec.t;
  next_effect_id : int;
  effect_error : string option;
  last_core_response : string option;
  attachment_picker_open : bool;
  task_status_picker_open : bool;
  app_navigation_previews : node_projection Rrbvec.t;
  app_navigation_path : navigation_route Rrbvec.t;
  search_navigation_path : navigation_route Rrbvec.t;
}

type chat_action =
  | SelectGraph of string
  | BeginSync
  | SyncSucceeded
  | SyncFailed of string
  | OpenSearch
  | ChangeSearchQuery of string
  | ApplySearchResults of string * search_hit Rrbvec.t
  | ApplyCoreSnapshot of core_projection
  | BeginOutlinerEdit of string
  | ChangeOutlinerText of string * string * int
  | ReturnOutlinerEditor of string * string * int
  | BackspaceOutlinerEditor of string * string * int
  | MoveOutlinerCaret of string * int
  | ToggleOutlinerCollapsed of string
  | LongPressOutlinerBlock of string
  | BeginOutlinerDrag of string
  | DropOutlinerBlocks of string * string
  | PerformOutlinerToolbarAction of string
  | ChooseOutlinerAutocomplete of string
  | OpenOutlinerAsset of string
  | CloseSearch
  | ExpandComposer
  | FocusComposer
  | ApplyComposerDraft of string
  | SaveUISession
  | RestoreUISession of ui_session
  | ChangeComposerDraft of string
  | DismissComposer
  | SendComposer
  | StageComposerAsset of composer_asset
  | RemoveComposerAsset of string
  | DequeueEffect of int
  | ResolveEffect of int * bool * string
  | OpenAttachmentPicker
  | CloseAttachmentPicker
  | ChooseAttachment of string
  | OpenTaskStatusPicker
  | CloseTaskStatusPicker
  | ChooseTaskStatus of string
  | ClearTaskStatus
  | RequestAppNode of string
  | ResolveAppNode of string * bool
  | BackAppNavigation of int
  | RequestSearchNode of string
  | ResolveSearchNode of string * bool
  | BackSearchNavigation of int
  | AddRootBlock of string
  | LoadOlderJournals
  | OpenSidebar
  | CloseSidebar
  | OpenGraphMenu
  | DismissGraphMenu
  | SelectSidebarGraph of string
  | SelectSidebarPage of string
  | OpenQuickAction of string
  | ShowJournals
  | ShowFlashcards
  | ShowGraphs
  | ApplyLocalGraphIds of string Rrbvec.t
  | ApplyGraphLoading of bool
  | RefreshGraphs
  | RequestOpenGraph of string
  | ChangeGraphPassword of string
  | SubmitGraphPassword
  | CancelGraphUnlock
  | OpenCreateGraph
  | DismissCreateGraph
  | ChangeNewGraphName of string
  | ToggleNewGraphEncrypted of bool
  | SubmitCreateGraph
  | RequestDeleteGraph of string
  | CancelDeleteGraph
  | ConfirmDeleteGraph
  | ApplyAuthentication of string * string option
  | SignIn
  | ApplySettingsSnapshot of settings_projection
  | OpenConnectionMenu
  | CloseConnectionMenu
  | ToggleActivePageFavorite
  | ShareActivePage
  | RequestDeleteActivePage
  | CancelDeleteActivePage
  | ConfirmDeleteActivePage
  | OpenSyncDetails
  | CloseSyncDetails
  | SyncNow
  | SetOutlinerTaskStatus of string * string
  | OpenSettings
  | DismissSettings
  | OpenSettingsTabs
  | BackSettings
  | OpenSettingsAppearanceMenu
  | CloseSettingsAppearanceMenu
  | ChangeAppearance of string
  | OpenSettingsLanguageMenu
  | CloseSettingsLanguageMenu
  | ChooseSettingsLanguage of string
  | ToggleSpellCheck of bool
  | ToggleAutoCorrection of bool
  | ToggleSidebarTab of string
  | MoveSidebarTab of string * int
  | ChangeBaseURL of string
  | ApplySettings
  | ExportGraphDatabase
  | OpenExternalURL of string
  | OpenRuntimeLog
  | DismissRuntimeLog
  | ToggleRuntimeLogErrors
  | ToggleRuntimeLogOrder
  | ToggleRuntimeLogSource
  | ApplyRuntimeLog of runtime_log_record Rrbvec.t
  | RefreshRuntimeLog
  | CopyRuntimeLog
  | SignOut
  | RevealFlashcardCloze
  | RevealFlashcardAnswer
  | ReviewFlashcard of string

val task_status : string -> string -> string -> string -> task_status

val built_in_task_statuses : unit -> task_status Rrbvec.t

val settings_language_choices : unit -> settings_language_choice Rrbvec.t

val settings_community_links : unit -> settings_community_link Rrbvec.t

val settings_language_by_id :
  settings_language_choice Rrbvec.t -> string -> settings_language_choice option

val settings_language_choice_selected_ : chat_model -> settings_language_choice -> bool

val initial : unit -> chat_model

val journal_section_key : outline_row -> string option

val refresh_journal_window :
  outline_row Rrbvec.t -> outline_row Rrbvec.t -> outline_row Rrbvec.t

val journal_section_title : outline_row -> string

val journal_section_markers : outline_row Rrbvec.t -> journal_section_marker Rrbvec.t

val finish_journal_section :
  journal_section_marker Rrbvec.t -> outline_row option -> int -> int ->
  journal_section_marker Rrbvec.t

val node_route_by_uuid : node_projection Rrbvec.t -> string -> node_projection option

val journal_preview_route : chat_model -> string -> node_projection option

val outliner_preview_end_index : outline_row Rrbvec.t -> int -> int -> int

val outliner_preview_route : chat_model -> string -> node_projection option

val publish_navigation_preview : chat_model -> string -> chat_model

val app_node_routes_from :
  chat_model -> navigation_route Rrbvec.t -> int -> node_projection Rrbvec.t

val app_node_routes : chat_model -> node_projection Rrbvec.t

val sidebar_page_in : sidebar_page Rrbvec.t -> string -> sidebar_page option

val sidebar_page_by_uuid : chat_model -> string -> sidebar_page option

val journal_rows_for_page : chat_model -> string -> outline_row Rrbvec.t

val preview_sidebar_page : chat_model -> string -> chat_model

val request_route : navigation_route Rrbvec.t -> navigation_route -> navigation_route Rrbvec.t

val resolve_route :
  navigation_route Rrbvec.t -> navigation_route -> bool -> navigation_route Rrbvec.t

val pop_route : navigation_route Rrbvec.t -> navigation_route Rrbvec.t

val remove_node_projection : node_projection Rrbvec.t -> string -> node_projection Rrbvec.t

val back_app_navigation : chat_model -> int -> chat_model

val back_search_navigation : chat_model -> int -> chat_model

val navigation_route_uuid : navigation_route -> string

val effect_id : chat_effect -> int

val effect_with_id : chat_effect Rrbvec.t -> int -> chat_effect option

val contains_sign_in_effect_ : chat_effect Rrbvec.t -> bool

val contains_load_older_journals_effect_ : chat_effect Rrbvec.t -> bool

val load_older_journals_active_ : chat_model -> bool

val graph_effect_key : chat_effect -> string

val contains_graph_effect_ : chat_effect Rrbvec.t -> string -> bool

val graph_effect_active_ : chat_model -> string -> bool

val graph_refresh_active_ : chat_model -> bool

val graph_create_active_ : chat_model -> bool

val graph_unlock_active_ : chat_model -> bool

val graph_delete_active_ : chat_model -> string -> bool

val sign_in_active_ : chat_model -> bool

val change_outliner_text_effect_for_ : chat_effect -> string -> bool

val contains_change_outliner_text_effect_ : chat_effect Rrbvec.t -> string -> bool

val change_outliner_text_active_ : chat_model -> string -> bool

val snapshot_outliner_editing : chat_model -> core_projection -> outliner_editing option

val first_flashcard_id : flashcard Rrbvec.t -> string option

val graph_by_id : graph Rrbvec.t -> string -> graph option

val task_status_by_id : task_status Rrbvec.t -> string -> task_status option

val task_status_identity : task_status -> string

val contains_task_status_identity_ : task_status Rrbvec.t -> string -> bool

val available_task_statuses : task_status Rrbvec.t -> task_status Rrbvec.t

val string_vector_contains_ : string Rrbvec.t -> string -> bool

val graph_local_ : chat_model -> string -> bool

val remove_string : string Rrbvec.t -> string -> string Rrbvec.t

val required_sidebar_tab_ : string -> bool

val valid_sidebar_tab_ : string -> bool

val normalize_sidebar_tabs : string Rrbvec.t -> string Rrbvec.t

val toggle_sidebar_tab : string Rrbvec.t -> string -> string Rrbvec.t

val move_sidebar_tab : string Rrbvec.t -> string -> int -> string Rrbvec.t

val bounded_url_delimiter : int -> int -> int

val valid_base_url_ : string -> bool

val valid_attachment_kind_ : string -> bool

val valid_authentication_state_ : string -> bool

val current_settings : chat_model -> settings_projection

val active_page : chat_model -> sidebar_page option

val page_is_favorite_ : chat_model -> string -> bool

val page_share_text : sidebar_page -> outline_row Rrbvec.t -> string

val page_share_asset_paths : outline_row Rrbvec.t -> string Rrbvec.t

val rollback_navigation_effect : chat_model -> chat_effect -> chat_model

val resolve_successful_effect : chat_model -> chat_effect -> string -> chat_model

val resolve_failed_effect : chat_model -> chat_effect -> string -> chat_model

val enqueue_close_search_effects : chat_model -> navigation_route Rrbvec.t -> chat_model

val enqueue_effect : chat_model -> chat_effect -> chat_model

val enqueue_open_graph : chat_model -> string -> chat_model

val persist_settings_change : chat_model -> chat_model -> chat_model

val update_editing : chat_model -> string -> string -> int -> chat_model

val row_index : outline_row Rrbvec.t -> string -> int option

val contains_row_ : outline_row Rrbvec.t -> string -> bool

val splice_start : outline_row Rrbvec.t -> outline_row_splice -> int option

val apply_row_splice : outline_row Rrbvec.t -> outline_row_splice -> outline_row Rrbvec.t

val apply_row_splices :
  outline_row Rrbvec.t -> outline_row_splice Rrbvec.t -> outline_row Rrbvec.t

val merge_row_replacements :
  outline_row Rrbvec.t -> outline_row Rrbvec.t -> outline_row Rrbvec.t

val remove_effect : chat_effect Rrbvec.t -> int -> chat_effect Rrbvec.t

val remove_search_effects : chat_effect Rrbvec.t -> chat_effect Rrbvec.t

val remove_composer_draft_effects : chat_effect Rrbvec.t -> chat_effect Rrbvec.t

val update : chat_model -> chat_action -> chat_model

val editing_sync_state : chat_model -> sync_state

val composer_assets_sending_ : chat_model -> bool

val ui_session : chat_model -> ui_session

val restore_session_routes : chat_model -> navigation_route Rrbvec.t -> bool -> chat_model

val restore_ui_session : chat_model -> ui_session -> chat_model
