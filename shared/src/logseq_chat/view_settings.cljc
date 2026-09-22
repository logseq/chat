(ns logseq-chat.view-settings
  (:require [logseq-chat.view-base :as base]
            [lui.elements :as elements]
            [lui.macros :refer [defui reactive event host?]]
            [lui.protocol :as proto :refer [TextChanged]]
            [lui.ui :as ui]
            [logseq-chat.model :as model]
            [signal.core :as signal]))

(defn settings-language-choice-radio [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<model/settings-language-choice> choice-source send]
  (let [choice (signal/sample choice-source)]
    (elements/element
     ui-context nil
     [:radio
      {:checked (reactive model/settings-language-choice-selected?
                          model-source choice-source)
       :accessibility-identifier (base/settings-language-choice-identifier choice)
       :on-change
       (fn [_event] (send (model/ChooseSettingsLanguage (:id choice))))}
      (base/settings-language-choice-title choice)])))

(defn settings-language-choice-menu-item [^ui/ui-context ui-context ^:signal<model/settings-language-choice> choice-source send]
  (let [choice (signal/sample choice-source)]
    (elements/element
     ui-context nil
     [:menu-item
      {:text (reactive base/settings-language-choice-title choice-source)
       :accessibility-identifier (base/settings-language-choice-identifier choice)
       :on-press
       (fn [_event] (send (model/ChooseSettingsLanguage (:id choice))))}])))

(defui settings-language-control [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:stack
      {:accessibility-identifier "layout.settings.language-control"}
      [:select
       {:text (reactive base/settings-language-title model-source)
        :label "Language"
        :accessibility-identifier "picker.settings.language"
        :on-press (fn [_event] (send model/OpenSettingsLanguageMenu))}]
      [:if {:test (reactive base/model-settings-language-menu-open? model-source)}
       [:dropdown-menu
        {:anchor "below"
         :anchor-alignment "end"
         :min-width 220
         :on-dismiss (fn [_event] (send model/CloseSettingsLanguageMenu))}
        [:keyed
         {:source (reactive base/model-language-choices model-source)
          :key base/settings-language-choice-identifier
          :compare compare
          :as choice-source}
         [settings-language-choice-menu-item choice-source send]]]]])
    (elements/element
     ui-context nil
     [:radio-group
      {:label "Language"
       :class "menu"
       :accessibility-identifier "picker.settings.language"}
      [:keyed
       {:source (reactive base/model-language-choices model-source)
        :key base/settings-language-choice-identifier
        :compare compare
        :as choice-source}
       [settings-language-choice-radio model-source choice-source send]]])))

(defui settings-appearance-control [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:stack
      {:accessibility-identifier "layout.settings.appearance-control"}
      [:select
       {:text (reactive base/settings-appearance-title model-source)
        :label "Theme"
        :accessibility-identifier "picker.settings.appearance"
        :on-press (fn [_event] (send model/OpenSettingsAppearanceMenu))}]
      [:if {:test (reactive base/model-settings-appearance-menu-open? model-source)}
       [:dropdown-menu
        {:anchor "below"
         :anchor-alignment "end"
         :min-width 160
         :on-dismiss (fn [_event] (send model/CloseSettingsAppearanceMenu))}
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "system")))}
         "System"]
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "light")))}
         "Light"]
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "dark")))}
         "Dark"]]]])
    (elements/element
     ui-context nil
     [:stack
      [:select
       {:text (reactive base/settings-appearance-title model-source)
        :label "Theme"
        :on-press (fn [_event] (send model/OpenSettingsAppearanceMenu))}]
      [:if {:test (reactive base/model-settings-appearance-menu-open? model-source)}
       [:dropdown-menu
        {:anchor "below"
         :anchor-alignment "end"
         :min-width 160
         :on-dismiss (fn [_event] (send model/CloseSettingsAppearanceMenu))}
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "system")))}
         "System"]
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "light")))}
         "Light"]
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "dark")))}
         "Dark"]]]])))

(defn settings-community-link-row [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<model/settings-community-link> link-source send]
  (let [link (signal/sample link-source)]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:column {:gap 12}
        [:list-item
         {:text (reactive base/settings-community-link-title link-source)
          :icon "app:open-external"
          :padding 0
          :accessibility-identifier
          (base/settings-community-link-identifier link)
          :on-press
          (event [current-link link-source]
                 (send (model/OpenExternalURL (:url current-link))))}]
        [:if
         {:test
          (reactive base/settings-community-link-needs-separator?
                    model-source link-source)}
         [:separator]]])
      (elements/element
       ui-context nil
       [:column {:gap 12}
        [:list-item
         {:text (reactive base/settings-community-link-title link-source)
          :padding 0
          :accessibility-identifier
          (base/settings-community-link-identifier link)
          :on-press
          (event [current-link link-source]
                 (send (model/OpenExternalURL (:url current-link))))}]
        [:if
         {:test
          (reactive base/settings-community-link-needs-separator?
                    model-source link-source)}
         [:separator]]]))))

(defn runtime-log-row [^ui/ui-context ui-context ^:signal<model/runtime-log-record> record-source]
  (elements/element
   ui-context nil
   [:column {:gap 3}
    [:row {:gap 6}
     [:if {:test (reactive base/runtime-log-error? record-source)}
      [:text {:value (reactive base/runtime-log-level record-source)
              :class "caption semibold"
              :foreground "red"}]]
     [:if {:test (reactive (fn [record] (not (base/runtime-log-error? record)))
                           record-source)}
      [:text {:value (reactive base/runtime-log-level record-source)
              :class "caption semibold"
              :foreground "secondary"}]]
     [:text {:value (reactive base/runtime-log-timestamp record-source)
             :class "caption"
             :foreground "secondary"}]]
    [:text {:value (reactive base/runtime-log-message record-source)
            :class "caption"}]
    [:separator]]))

(defn settings-tab-row [^ui/ui-context ui-context ^:signal<model/chat-model> model-source tab title send]
  (let [label-source
        (reactive (fn [current] (base/tab-toggle-label current tab)) model-source)
        toggle-disabled-source
        (reactive (fn [_current] (model/required-sidebar-tab? tab)) model-source)
        movement-visible-source
        (reactive (fn [current] (base/tab-movement-visible? current tab)) model-source)
        up-disabled-source
        (reactive (fn [current] (base/tab-move-up-disabled? current tab)) model-source)
        down-disabled-source
        (reactive (fn [current] (base/tab-move-down-disabled? current tab)) model-source)
        selection-glyph-source
        (reactive (fn [current] (base/tab-selection-glyph current tab)) model-source)
        selection-icon-source
        (reactive (fn [current] (base/tab-selection-icon-name current tab)) model-source)]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:row
        {:cross "center"
         :padding 8
         :background "surface-container-low"
         :corner-radius 12
         :accessibility-identifier (str "row.settings.tab." tab)}
        [:row {:grow 1.0 :cross "center" :gap 8}
         [:button
          {:label label-source
           :icon selection-icon-source
           :icon-placement "trailing"
           :accessibility-label label-source
           :variant "ghost"
           :disabled toggle-disabled-source
           :accessibility-identifier (base/tab-toggle-identifier tab)
           :on-press (fn [_event] (send (model/ToggleSidebarTab tab)))}
          title]
         [:spacer]
         [:if {:test movement-visible-source}
          [:button
           {:icon "app:arrow-up"
            :size "icon"
            :disabled up-disabled-source
            :variant "ghost"
            :label "Move tab up"
            :accessibility-identifier (base/tab-up-identifier tab)
            :on-press
            (fn [_event] (send (model/MoveSidebarTab tab -1)))}]]
         [:if {:test movement-visible-source}
          [:button
           {:icon "app:arrow-down"
            :size "icon"
            :disabled down-disabled-source
            :variant "ghost"
            :label "Move tab down"
            :accessibility-identifier (base/tab-down-identifier tab)
            :on-press
            (fn [_event] (send (model/MoveSidebarTab tab 1)))}]]]])
      (elements/element
       ui-context nil
       [:list-item
        {:accessibility-identifier (str "row.settings.tab." tab)}
        [:row {:grow 1.0 :cross "center" :gap 8}
         [:button
          {:label label-source
           :grow 1.0
           :variant "ghost"
           :disabled toggle-disabled-source
           :accessibility-identifier (base/tab-toggle-identifier tab)
           :on-press (fn [_event] (send (model/ToggleSidebarTab tab)))}
          title]
         [:text {:value selection-glyph-source :foreground "accent"}]
         [:if {:test movement-visible-source}
          [:button
           {:disabled up-disabled-source
            :variant "ghost"
            :label "Move tab up"
            :accessibility-identifier (base/tab-up-identifier tab)
            :on-press
            (fn [_event] (send (model/MoveSidebarTab tab -1)))}
           "↑"]]
         [:if {:test movement-visible-source}
          [:button
           {:disabled down-disabled-source
            :variant "ghost"
            :label "Move tab down"
            :accessibility-identifier (base/tab-down-identifier tab)
            :on-press
            (fn [_event] (send (model/MoveSidebarTab tab 1)))}
           "↓"]]]]))))

(defui settings-tabs-screen [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:column
      {:grow 1.0
       :cross "stretch"
       :gap 10
       :padding 16
       :accessibility-identifier "screen.settings.tabs"}
      [:text {:class "headline" :foreground "muted-foreground"}
       "Visible tabs"]
      [:list
       {:grow 1.0
        :gap 8
        :accessibility-identifier "list.settings.tabs"}
       [settings-tab-row model-source "journals" "Journals" send]
       [:if {:test (reactive base/settings-flashcards-before-graphs? model-source)}
        [settings-tab-row model-source "flashcards" "Flashcards" send]]
       [settings-tab-row model-source "graphs" "Graphs" send]
       [:if {:test (reactive base/settings-flashcards-after-graphs? model-source)}
        [settings-tab-row model-source "flashcards" "Flashcards" send]]
       [:text
        {:class "footnote" :foreground "muted-foreground"}
        "Journals and Graphs are always available. Use the arrows to reorder tabs."]
       [:if {:test (reactive base/settings-available-tabs-present? model-source)}
        [:text
         {:class "headline"
          :foreground "muted-foreground"
          :accessibility-identifier "text.settings.tabs.available"}
         "Available tabs"]]
       [:if {:test (reactive base/settings-available-tabs-present? model-source)}
        [settings-tab-row model-source "flashcards" "Flashcards" send]]]])
    (elements/element
     ui-context nil
     [:list {:accessibility-identifier "screen.settings.tabs"}
      [:heading "Visible tabs"]
      [settings-tab-row model-source "journals" "Journals" send]
      [:if {:test (reactive base/settings-flashcards-before-graphs? model-source)}
       [settings-tab-row model-source "flashcards" "Flashcards" send]]
      [settings-tab-row model-source "graphs" "Graphs" send]
      [:if {:test (reactive base/settings-flashcards-after-graphs? model-source)}
       [settings-tab-row model-source "flashcards" "Flashcards" send]]
      [:text
       {:class "footnote" :foreground "muted-foreground"}
       "Journals and Graphs are always available. Use the arrows to reorder tabs."]
      [:if {:test (reactive base/settings-available-tabs-present? model-source)}
       [:heading
        {:accessibility-identifier "text.settings.tabs.available"}
        "Available tabs"]]
      [:if {:test (reactive base/settings-available-tabs-present? model-source)}
       [settings-tab-row model-source "flashcards" "Flashcards" send]]])))

(defui runtime-log-toolbar [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
     (elements/element
      ui-context nil
      [:column {:gap 8 :cross "stretch"}
       [:toolbar
        {:orientation "horizontal"
         :gap 8
         :label "Log filters"
         :accessibility-identifier "toolbar.log-filters.primary"}
        [:button
         {:text (reactive base/runtime-log-errors-label model-source)
          :label "Toggle error filtering"
          :variant "secondary"
          :accessibility-identifier "button.log-errors"
          :on-press (fn [_event] (send model/ToggleRuntimeLogErrors))}
         "Errors only"]
        [:button
         {:text (reactive base/runtime-log-order-label model-source)
          :label "Toggle log ordering"
          :variant "secondary"
          :accessibility-identifier "button.log-order"
          :on-press (fn [_event] (send model/ToggleRuntimeLogOrder))}
         "Newest first"]]
       [:toolbar
        {:orientation "horizontal"
         :gap 8
         :label "Log actions"
         :accessibility-identifier "toolbar.log-filters.secondary"}
        [:button
         {:text (reactive base/runtime-log-source-label model-source)
          :label "Toggle log source"
          :variant "secondary"
          :accessibility-identifier "button.log-source"
          :on-press (fn [_event] (send model/ToggleRuntimeLogSource))}
         "Core log"]
        [:button
         {:variant "secondary"
          :accessibility-identifier "button.log-copy"
          :on-press (fn [_event] (send model/CopyRuntimeLog))}
         "Copy"]]])
     (elements/element
      ui-context nil
      [:toolbar
       {:orientation "horizontal"
        :class "scroll"
        :gap 8
        :label "Log filters"}
       [:button
        {:text (reactive base/runtime-log-errors-label model-source)
         :label "Toggle error filtering"
         :variant "secondary"
         :accessibility-identifier "button.log-errors"
         :on-press (fn [_event] (send model/ToggleRuntimeLogErrors))}
        "Errors only"]
       [:button
        {:text (reactive base/runtime-log-order-label model-source)
         :label "Toggle log ordering"
         :variant "secondary"
         :accessibility-identifier "button.log-order"
         :on-press (fn [_event] (send model/ToggleRuntimeLogOrder))}
        "Newest first"]
       [:button
        {:text (reactive base/runtime-log-source-label model-source)
         :label "Toggle log source"
         :variant "secondary"
         :accessibility-identifier "button.log-source"
         :on-press (fn [_event] (send model/ToggleRuntimeLogSource))}
        "Core log"]
       [:button
        {:variant "secondary"
         :accessibility-identifier "button.log-copy"
         :on-press (fn [_event] (send model/CopyRuntimeLog))}
        "Copy"]])))

(defui runtime-log-screen [^:signal<model/chat-model> model-source send]
  [:column {:gap 12
            :padding 16
            :grow 1.0
            :accessibility-identifier "screen.runtime-log"
            :background "background"}
   [runtime-log-toolbar model-source send]
   [:scroll {:grow 1.0}
    [:column {:gap 10}
     [:if {:test (reactive base/runtime-log-empty? model-source)}
      [:text {:foreground "secondary"} "No log entries"]]
     [:keyed
      {:source (reactive base/runtime-log-records model-source)
       :key base/runtime-log-record-identifier
       :compare compare
       :as record-source}
      [runtime-log-row record-source]]]]])

(defn settings-toggle-spell-check [send input-event]
  (match input-event
    (proto/ToggleChanged _node enabled)
    (send (model/ToggleSpellCheck enabled))
    _ true))

(defn settings-toggle-auto-correction [send input-event]
  (match input-event
    (proto/ToggleChanged _node enabled)
    (send (model/ToggleAutoCorrection enabled))
    _ true))

(defui settings-general-card [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:column
      {:gap 12
       :cross "stretch"
       :padding 16
       :background "surface-container-low"
       :corner-radius 14
       :accessibility-identifier "layout.settings.general-card"}
      [settings-appearance-control model-source send]
      [:separator]
      [settings-language-control model-source send]
      [:separator]
      [:list-item
       {:padding 0
        :accessibility-identifier "link.settings.tabs"
        :on-press (fn [_event] (send model/OpenSettingsTabs))}
       [:row {:grow 1.0 :cross "center" :gap 12}
        [:column
         {:grow 1.0
          :gap 2
          :accessibility-identifier "layout.settings.tabs-copy"}
         [:text "Tabs"]
         [:text
          {:value (reactive base/settings-tabs-summary model-source)
           :class "footnote"
           :foreground "muted-foreground"
           :accessibility-identifier "text.settings.tabs.selection"}]]
        [:icon
         {:name "app:chevron-right"
          :width 20
          :height 20
          :foreground "muted-foreground"
          :accessibility-identifier "icon.settings.tabs"
          :accessibility-label "Open Tabs"}]]]])
    (elements/element
     ui-context nil
     [:column
      {:gap 12
       :padding 16
       :background "surface"
       :corner-radius 14
       :accessibility-identifier "layout.settings.general-card"}
      [:row {:cross "center"}
       [:text "Theme"]
       [:spacer]
       [settings-appearance-control model-source send]]
      [:separator]
      [:row {:cross "center"}
       [:text "Language"]
       [:spacer]
       [settings-language-control model-source send]]
      [:separator]
      [:list-item
       {:padding 0
        :accessibility-identifier "link.settings.tabs"
        :on-press (fn [_event] (send model/OpenSettingsTabs))}
       [:row {:grow 1.0 :cross "center"}
        [:text "Tabs"]
        [:spacer]
        [:text
         {:value (reactive base/settings-tabs-summary model-source)
          :class "single-line"
          :foreground "secondary"
          :accessibility-identifier "text.settings.tabs.selection"}]]]])))

(defn settings-editor-card [^ui/ui-context ui-context spell-check-source auto-correction-source send]
  (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:column
        {:gap 0
         :cross "stretch"
         :padding 16
         :background "surface-container-low"
         :corner-radius 14}
        [:switch
         {:checked spell-check-source
          :accessibility-identifier "switch.settings.spell-check"
          :on-toggle (fn [input-event]
                       (settings-toggle-spell-check send input-event))}
         "Spell check"]
        [:separator]
        [:switch
         {:checked auto-correction-source
          :accessibility-identifier "switch.settings.auto-correction"
          :on-toggle (fn [input-event]
                       (settings-toggle-auto-correction send input-event))}
         "Auto-correction"]])
    (elements/element
     ui-context nil
     [:column
      {:gap 12 :padding 16 :background "surface" :corner-radius 14}
      [:toggle
       {:checked spell-check-source
        :on-toggle (fn [input-event]
                     (settings-toggle-spell-check send input-event))}
       "Spell check"]
      [:separator]
      [:toggle
       {:checked auto-correction-source
        :on-toggle (fn [input-event]
                     (settings-toggle-auto-correction send input-event))}
      "Auto-correction"]])))

(defn settings-export-row [^ui/ui-context ui-context send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:list-item
      {:icon "app:download"
       :padding 0
       :accessibility-identifier "button.export-graph-database"
       :on-press (fn [_event] (send model/ExportGraphDatabase))}
      "Export Graph SQLite DB"])
    (elements/element
     ui-context nil
     [:list-item
      {:padding 0
       :accessibility-identifier "button.export-graph-database"
       :on-press (fn [_event] (send model/ExportGraphDatabase))}
      "Export Graph SQLite DB"])))

(defn settings-runtime-log-row [^ui/ui-context ui-context send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:list-item
      {:icon "app:terminal"
       :padding 0
       :accessibility-identifier "button.runtime-log"
       :on-press (fn [_event] (send model/OpenRuntimeLog))}
      "Check log"])
    (elements/element
     ui-context nil
     [:list-item
      {:padding 0
       :accessibility-identifier "button.runtime-log"
       :on-press (fn [_event] (send model/OpenRuntimeLog))}
      "Check log"])))

(defn settings-sign-out-row [^ui/ui-context ui-context send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:list-item
      {:icon "app:sign-out"
       :padding 0
       :accessibility-identifier "button.sign-out"
       :on-press (fn [_event] (send model/SignOut))}
      "Sign Out"])
    (elements/element
     ui-context nil
     [:list-item
      {:padding 0
       :accessibility-identifier "button.sign-out"
       :on-press (fn [_event] (send model/SignOut))}
      "Sign Out"])))

(defui settings-screen [^:signal<model/chat-model> model-source send]
  [:column
   {:gap 18
    :padding 20
    :background "background"
    :accessibility-identifier "screen.settings"}
   [:column {:gap 8}
    [:text
     {:class "headline"
      :foreground "muted-foreground"
      :accessibility-identifier "label.settings.general"}
     "General"]
    [settings-general-card model-source send]]
   [:column {:gap 8}
    [:text
     {:class "headline"
      :foreground "muted-foreground"
      :accessibility-identifier "label.settings.editor"}
     "Editor"]
    [settings-editor-card
     (reactive base/settings-spell-check model-source)
     (reactive base/settings-auto-correction model-source)
     send]]
   [:column {:gap 8}
    [:text
     {:class "headline"
      :foreground "muted-foreground"
      :accessibility-identifier "label.settings.sync-server"}
     "Sync server"]
    [:column
     {:gap 8
      :padding 16
      :background (if (host? proto/FlutterHost)
                    "surface-container-low"
                    "surface")
      :corner-radius 14}
     [:text-field
      {:text (reactive base/settings-base-url model-source)
       :placeholder "Server URL"
       :label "Server URL"
       :accessibility-identifier "field.base-url"
       :on-input
       (fn [input-event]
         (match input-event
           (TextChanged _node text) (send (model/ChangeBaseURL text))
           _ true))}]
     [:if {:test (reactive base/settings-base-url-invalid? model-source)}
      [:text {:foreground "destructive"}
       "Enter a valid HTTP or HTTPS URL."]]]]
   [:if {:test (reactive base/selected-graph-local? model-source)}
    [:column {:gap 8}
     [:text
      {:class "headline"
       :foreground "muted-foreground"
       :accessibility-identifier "label.settings.advanced"}
     "Advanced"]
     [:column
      {:padding 16
       :background (if (host? proto/FlutterHost)
                     "surface-container-low"
                     "surface")
       :corner-radius 14}
      [settings-export-row send]]]]
   [:column {:gap 8}
    [:text
     {:class "headline"
      :foreground "muted-foreground"
      :accessibility-identifier "label.settings.about"}
     "About"]
    [:column
     {:gap 12
      :padding 16
      :background (if (host? proto/FlutterHost)
                    "surface-container-low"
                    "surface")
      :corner-radius 14}
     [:row
      [:text "Version"]
      [:spacer]
      [:text {:value (reactive base/settings-version model-source)
              :foreground "secondary"}]]
     [:separator]
     [:row
      [:text "Revision"]
      [:spacer]
     [:text {:value (reactive base/settings-revision model-source)
              :foreground "secondary"}]]
     [:separator]
     [settings-runtime-log-row send]]]
   [:column {:gap 8}
    [:text
     {:class "headline"
      :foreground "muted-foreground"
      :accessibility-identifier "label.settings.community"}
     "Community"]
    [:column
     {:gap 12
      :background (if (host? proto/FlutterHost)
                    "surface-container-low"
                    "surface")
      :corner-radius 14
      :padding 16}
     [:keyed
      {:source (reactive base/model-community-links model-source)
       :key base/settings-community-link-identifier
       :compare compare
       :as link-source}
      [settings-community-link-row model-source link-source send]]]]
   [:column
    {:padding 16
     :background (if (host? proto/FlutterHost)
                   "surface-container-low"
                   "surface")
     :corner-radius 14}
    [settings-sign-out-row send]]])

(defui settings-main-sheet [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:sheet
      {:text "Settings"
       :height 640
       :accessibility-identifier "sheet.settings"
       :on-dismiss (fn [_event] (send model/DismissSettings))}
      [:column
       {:grow 1.0
        :gap 12
        :accessibility-identifier "layout.settings.sheet"}
       [:scroll {:grow 1.0}
        [settings-screen model-source send]]
       [:row
        {:gap 12
         :padding-horizontal 20
         :padding-vertical 12
         :background "surface-container-low"
         :accessibility-identifier "toolbar.settings.actions"}
        [:button
         {:variant "secondary"
          :grow 1.0
          :accessibility-identifier "button.connection.cancel"
          :on-press (fn [_event] (send model/DismissSettings))}
         "Cancel"]
        [:button
         {:variant "primary"
          :grow 1.0
          :accessibility-identifier "button.connection.apply"
          :disabled (reactive base/settings-apply-disabled? model-source)
          :on-press (fn [_event] (send model/ApplySettings))}
         "Apply"]]]])
    (elements/element
     ui-context nil
     [:sheet
      {:text "Settings"
       :class "navigation-scroll"
       :accessibility-identifier "sheet.settings"
       :on-dismiss (fn [_event] (send model/DismissSettings))}
      [settings-screen model-source send]
      [:if {:test (reactive base/settings-tabs-visible? model-source)}
       [settings-tabs-sheet model-source send]]
      [:if {:test (reactive base/runtime-log-visible? model-source)}
       [runtime-log-sheet model-source send]]
      [:toolbar
       {:orientation "horizontal"
        :label "Settings actions"
        :class "navigation-actions"
        :accessibility-identifier "toolbar.settings.actions"}
       [:button
        {:class "cancellation-action"
         :accessibility-identifier "button.connection.cancel"
         :on-press (fn [_event] (send model/DismissSettings))}
        "Cancel"]
       [:button
        {:class "confirmation-action"
         :accessibility-identifier "button.connection.apply"
         :disabled (reactive base/settings-apply-disabled? model-source)
         :on-press (fn [_event] (send model/ApplySettings))}
        "Apply"]]])))

(defui settings-tabs-sheet [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:sheet
      {:text "Tabs"
       :class "navigation-content"
       :accessibility-identifier "sheet.settings"
       :on-dismiss (fn [_event] (send model/BackSettings))}
      [:column
       {:grow 1.0
        :accessibility-identifier "layout.settings.tabs-sheet"}
       [settings-tabs-screen model-source send]
       [:row
        {:padding-horizontal 16
         :padding-vertical 12
         :background "surface-container-low"
         :accessibility-identifier "toolbar.settings.actions"}
        [:button
         {:variant "secondary"
          :grow 1.0
          :accessibility-identifier "button.connection.cancel"
          :on-press (fn [_event] (send model/BackSettings))}
         "Back to Settings"]]]])
    (elements/element
     ui-context nil
     [:sheet
      {:text "Tabs"
       :class "navigation-list"
       :accessibility-identifier "sheet.settings.tabs"
       :on-dismiss (fn [_event] (send model/BackSettings))}
      [settings-tabs-screen model-source send]
      [:toolbar
       {:orientation "horizontal"
        :label "Tabs actions"
        :class "navigation-actions"
        :accessibility-identifier "toolbar.settings.actions"}
       [:button
        {:class "cancellation-action navigation-back-action"
         :accessibility-identifier "button.connection.cancel"
         :on-press (fn [_event] (send model/BackSettings))}
        "Settings"]]])))

(defn runtime-log-actions [^ui/ui-context ui-context send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:row
      {:gap 12
       :padding-horizontal 16
       :padding-vertical 12
       :background "surface-container-low"
       :accessibility-identifier "toolbar.settings.actions"}
      [:button
       {:variant "secondary"
        :grow 1.0
        :accessibility-identifier "button.log-refresh"
        :on-press (fn [_event] (send model/RefreshRuntimeLog))}
       "Refresh"]
      [:button
       {:variant "primary"
        :grow 1.0
        :accessibility-identifier "button.connection.apply"
        :on-press (fn [_event] (send model/DismissRuntimeLog))}
       "Done"]])
    (elements/element
     ui-context nil
     [:toolbar
      {:orientation "horizontal"
       :label "Log actions"
       :class "navigation-actions"
       :accessibility-identifier "toolbar.settings.actions"}
      [:button
       {:class "cancellation-action"
        :accessibility-identifier "button.log-refresh"
        :on-press (fn [_event] (send model/RefreshRuntimeLog))}
       "Refresh"]
      [:button
       {:class "confirmation-action"
        :accessibility-identifier "button.connection.apply"
        :on-press (fn [_event] (send model/DismissRuntimeLog))}
       "Done"]])))

(defui runtime-log-sheet [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:sheet
      {:text "Log"
       :class "navigation-content"
       :accessibility-identifier "sheet.settings"
       :on-dismiss (fn [_event] (send model/DismissRuntimeLog))}
      [:column
       {:grow 1.0
       :gap 12
        :accessibility-identifier "layout.runtime-log.sheet"}
       [runtime-log-screen model-source send]
       [runtime-log-actions send]]])
    (elements/element
     ui-context nil
     [:sheet
      {:text "Log"
       :class "navigation-content"
       :accessibility-identifier "sheet.settings.log"
       :on-dismiss (fn [_event] (send model/DismissRuntimeLog))}
      [runtime-log-screen model-source send]
      [runtime-log-actions send]])))

(defui settings-sheet [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element ui-context nil
     [:stack
      [:if {:test (reactive base/settings-main-visible? model-source)}
       [settings-main-sheet model-source send]]
      [:if {:test (reactive base/settings-tabs-visible? model-source)}
       [settings-tabs-sheet model-source send]]
      [:if {:test (reactive base/runtime-log-visible? model-source)}
       [runtime-log-sheet model-source send]]])
    (settings-main-sheet ui-context model-source send)))

(defui page-delete-dialog [send]
  [:dialog
   {:text "Delete page?"
    :class "alert"
    :accessibility-identifier "dialog.page-delete"
    :on-dismiss (fn [_event] (send model/CancelDeleteActivePage))}
   [:column
    [:text "The page will be moved to Recycle."]
    [:button
     {:accessibility-identifier "button.page-delete.cancel"
      :on-press (fn [_event] (send model/CancelDeleteActivePage))}
     "Cancel"]
    [:button
     {:accessibility-identifier "button.page-delete.confirm"
      :on-press (fn [_event] (send model/ConfirmDeleteActivePage))}
     "Delete"]]])

(defui sync-status-sheet [^:signal<model/chat-model> model-source send]
  [:sheet
   {:text "Sync status"
    :class "navigation-form"
    :accessibility-identifier "sheet.sync-status"
    :on-dismiss (fn [_event] (send model/CloseSyncDetails))}
   [:column
    {:class "form"
     :accessibility-identifier "form.sync-status"}
    [:list-item {:accessibility-identifier "row.sync.status"}
     [:row {:grow 1.0 :cross "center" :main "space_between"}
      [:text "Status"]
      [:text {:value (reactive base/sync-label model-source)
              :foreground "secondary"
              :text-alignment "end"}]]]
    [:list-item {:accessibility-identifier "row.sync.graph"}
     [:row {:grow 1.0 :cross "center" :main "space_between"}
      [:text "Graph"]
      [:text {:value (reactive base/graph-label model-source)
              :foreground "secondary"
              :text-alignment "end"}]]]
    [:list-item {:accessibility-identifier "row.sync.connection"}
     [:row {:grow 1.0 :cross "center" :main "space_between"}
      [:text "Connection"]
      [:text {:value (reactive base/sync-connection-label model-source)
              :foreground "secondary"
              :text-alignment "end"}]]]
    [:list-item {:accessibility-identifier "row.sync.pending"}
     [:row {:grow 1.0 :cross "center" :main "space_between"}
      [:text "Local changes"]
      [:text
       {:value (reactive base/sync-pending-label model-source)
        :foreground "secondary"
        :text-alignment "end"
        :accessibility-identifier "sync.pending"}]]]
    [:list-item {:accessibility-identifier "row.sync.cursor"}
     [:row {:grow 1.0 :cross "center" :main "space_between"}
      [:text "Server cursor"]
      [:text
       {:value (reactive base/sync-cursor-label model-source)
        :foreground "secondary"
        :text-alignment "end"
        :accessibility-identifier "sync.cursor"}]]]
    [:if {:test (reactive base/sync-error-present? model-source)}
     [:heading {:level 5} "Last error"]]
    [:if {:test (reactive base/sync-error-present? model-source)}
     [:list-item
      [:text
       {:value (reactive base/sync-error-message model-source)
        :foreground "red"
        :accessibility-identifier "sync.error"}]]]
    [:button
     {:accessibility-identifier "button.sync-now"
      :on-press (fn [_event] (send model/SyncNow))}
     "Sync now"]]
   [:toolbar
    {:orientation "horizontal"
     :label "Sync status actions"
     :class "navigation-actions"
     :accessibility-identifier "toolbar.sync.actions"}
    [:button
     {:class "confirmation-action"
      :accessibility-identifier "button.sync.done"
      :on-press (fn [_event] (send model/CloseSyncDetails))}
     "Done"]]])
