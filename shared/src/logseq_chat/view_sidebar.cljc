(ns logseq-chat.view-sidebar
  (:require [logseq-chat.view-base :as base]
            [lui.elements :as elements]
            [lui.macros :refer [defui reactive event host?]]
            [lui.protocol :as proto :refer [TextChanged]]
            [lui.ui :as ui]
            [logseq-chat.model :as model]
            [signal.core :as signal]))

(defn sidebar-page-row [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<model/sidebar-page> page-source send]
  (let [page (signal/sample page-source)]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:list-item
        {:text (reactive base/sidebar-page-title page-source)
         :label (reactive base/sidebar-page-title page-source)
         :icon "app:document"
         :selected (reactive base/sidebar-page-selected? model-source page-source)
         :accessibility-identifier (base/sidebar-page-identifier page)
         :on-press
         (event [current-page page-source]
                (send (model/SelectSidebarPage (:uuid current-page))))}])
      (elements/element
       ui-context nil
       [:list-item
        {:text (reactive base/sidebar-page-title page-source)
         :label (reactive base/sidebar-page-title page-source)
         :role "navigation"
         :icon "app:document"
         :selected (reactive base/sidebar-page-selected? model-source page-source)
         :accessibility-identifier (base/sidebar-page-identifier page)
         :on-press
         (event [current-page page-source]
                (send (model/SelectSidebarPage (:uuid current-page))))}]))))

(defn sidebar-graph-menu-item [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<model/graph> graph-source send]
  (let [graph (signal/sample graph-source)]
    (elements/element
     ui-context nil
     [:menu-item
      {:text (reactive base/graph-title graph-source)
       :selected (reactive base/sidebar-graph-selected? model-source graph-source)
       :disabled (reactive base/sidebar-graph-disabled? graph-source)
       :accessibility-identifier (base/sidebar-graph-identifier graph)
       :on-press
       (event [current-graph graph-source]
              (send (model/SelectSidebarGraph (:id current-graph))))}])))

(defui sidebar-section-heading [^:string title ^:string icon]
  [:column {:gap 0}
   [:box {:height 16}]
   [:row {:gap 6
          :cross "center"
          :padding-horizontal 12}
    [:icon {:name icon :width 14 :height 14 :foreground "muted-foreground"}]
    [:text {:class "caption semibold" :foreground "muted-foreground"} title]]
   [:box {:height 6}]])

(defui sidebar-empty-section-label [title]
  [:column {:gap 0}
   [:row {:padding-horizontal 12}
    [:text {:class "caption" :foreground "muted-foreground"} title]]
   [:box {:height 6}]])

(defui sidebar-graph-switch-content [^:signal<model/chat-model> model-source]
  [:row {:grow 1.0 :main "space_between" :cross "center"}
   [:text {:value (reactive base/graph-label model-source)}]
   [:icon {:name "app:chevron-down"
           :width 18
           :height 18
           :foreground "muted-foreground"}]])

(defn sidebar-graph-switch [^ui/ui-context ui-context ^:signal<model/chat-model> model-source send]
  (let [_label (base/graph-label (signal/sample model-source))]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:list-item
        {:label "Switch graph"
         :accessibility-identifier "button.graph-switch"
         :on-press (fn [_event] (send model/OpenGraphMenu))}
        [sidebar-graph-switch-content model-source]])
      (elements/element
       ui-context nil
       [:list-item
        {:text (reactive base/graph-label model-source)
         :label "Switch graph"
         :role "navigation-heading"
         :icon "app:chevron-down"
         :icon-placement "trailing"
         :accessibility-identifier "button.graph-switch"
         :on-press (fn [_event] (send model/OpenGraphMenu))}]))))

(defn sidebar-journals-row [^ui/ui-context ui-context ^:signal<model/chat-model> model-source send]
  (let [_selected (base/journals-sidebar-selected? (signal/sample model-source))]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:list-item
        {:label "Journals"
         :icon "app:calendar"
         :selected (reactive base/journals-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.journals"
         :on-press (fn [_event] (send model/ShowJournals))}
        "Journals"])
      (elements/element
       ui-context nil
       [:list-item
        {:label "Journals"
         :role "navigation"
         :icon "app:calendar"
         :selected (reactive base/journals-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.journals"
         :on-press (fn [_event] (send model/ShowJournals))}
        "Journals"]))))

(defn sidebar-flashcards-row [^ui/ui-context ui-context ^:signal<model/chat-model> model-source send]
  (let [_selected (base/flashcards-sidebar-selected? (signal/sample model-source))]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:list-item
        {:label "Flashcards"
         :icon "app:flashcards"
         :selected (reactive base/flashcards-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.flashcards"
         :on-press (fn [_event] (send model/ShowFlashcards))}
        "Flashcards"])
      (elements/element
       ui-context nil
       [:list-item
        {:label "Flashcards"
         :role "navigation"
         :icon "app:flashcards"
         :selected (reactive base/flashcards-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.flashcards"
         :on-press (fn [_event] (send model/ShowFlashcards))}
        "Flashcards"]))))

(defn sidebar-graphs-row [^ui/ui-context ui-context ^:signal<model/chat-model> model-source send]
  (let [_selected (base/graphs-sidebar-selected? (signal/sample model-source))]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:list-item
        {:label "Graphs"
         :icon "app:folder"
         :selected (reactive base/graphs-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.graphs"
         :on-press (fn [_event] (send model/ShowGraphs))}
        "Graphs"])
      (elements/element
       ui-context nil
       [:list-item
        {:label "Graphs"
         :role "navigation"
         :icon "app:folder"
         :selected (reactive base/graphs-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.graphs"
         :on-press (fn [_event] (send model/ShowGraphs))}
        "Graphs"]))))

(defui sidebar-view [^:signal<model/chat-model> model-source send]
  [:column
   {:accessibility-identifier "sidebar.navigation"
    :grow 1.0
    :gap 4
    :padding 12}
   [:box {:height (if (host? proto/FlutterHost) 8 48)}]
   [:stack
    [sidebar-graph-switch model-source send]
    [:if {:test (reactive base/model-graph-menu-open? model-source)}
     [:dropdown-menu
      {:anchor "below"
       :anchor-alignment "start"
       :min-width 240
       :accessibility-identifier "menu.graph-switch"
       :on-dismiss (fn [_event] (send model/DismissGraphMenu))}
      [:keyed
       {:source (reactive (fn [current] (:graphs current)) model-source)
        :key base/sidebar-graph-identifier
        :compare compare
        :as graph-source}
       [sidebar-graph-menu-item model-source graph-source send]]]]]
   [:box {:height 12}]
   [sidebar-journals-row model-source send]
   [:if {:test (reactive base/flashcards-tab-visible? model-source)}
    [sidebar-flashcards-row model-source send]]
   [:if {:test (reactive base/graphs-tab-visible? model-source)}
    [sidebar-graphs-row model-source send]]
   [:scroll {:grow 1.0 :accessibility-identifier "scroll.sidebar.pages"}
    [:column {:gap 4}
     [:column {:accessibility-identifier "section.sidebar.favorites" :gap 2}
      [sidebar-section-heading "Favorites" "app:star"]
      [:if {:test (reactive base/favorites-empty? model-source)}
       [sidebar-empty-section-label "No favorites yet"]]
      [:keyed
       {:source (reactive base/sidebar-favorites model-source)
        :key base/sidebar-page-identifier
        :compare compare
        :as page-source}
       [sidebar-page-row model-source page-source send]]]
     [:column {:accessibility-identifier "section.sidebar.recent" :gap 2}
      [sidebar-section-heading "Recent" "app:history"]
      [:if {:test (reactive base/recent-pages-empty? model-source)}
       [sidebar-empty-section-label "No recent pages"]]
      [:keyed
       {:source (reactive base/sidebar-recent-pages model-source)
        :key base/sidebar-page-identifier
        :compare compare
        :as page-source}
       [sidebar-page-row model-source page-source send]]]]]])
