(ns logseq-chat.view-flashcards
  (:require [logseq-chat.view-base :as base]
            [lui.elements :as elements]
            [lui.macros :refer [defui reactive]]
            [lui.ui :as ui]
            [logseq-chat.model :as model]
            [signal.core :as signal]))

(defn flashcard-answer-row [^ui/ui-context ui-context ^:signal<model/flashcard-answer-row> answer-source]
  (let [answer (signal/sample answer-source)]
    (elements/element
     ui-context nil
     [:text
      {:value (reactive base/flashcard-answer-text answer-source)
       :accessibility-identifier (base/flashcard-answer-identifier answer)}])))

;; Flashcard controls use shared button typography and alignment semantics.

(defui flashcard-rating-button [rating title foreground background send]
  [:button
   {:variant "ghost"
    :class "semibold"
    :grow 1.0
    :min-height 50
    :text-alignment "center"
    :foreground foreground
    :background background
    :corner-radius 14
    :accessibility-identifier (str "button.flashcard.rating." rating)
    :on-press (fn [_event] (send (model/ReviewFlashcard rating)))}
   title])

(defui flashcard-review-content [^:signal<model/chat-model> model-source send]
  [:column
   {:accessibility-identifier "layout.flashcards.review"
    :grow 1.0
    :gap 0
    :padding-horizontal 20}
   [:box
    {:height 18
     :accessibility-identifier "spacer.flashcards.top"}]
   [:column
    {:accessibility-identifier "layout.flashcards.review-content"
     :grow 1.0
     :gap 18}
    [:row
     {:accessibility-identifier "row.flashcards.status"}
     [:text {:class "footnote" :foreground "muted-foreground"} "Due now"]
     [:spacer {:grow 1.0}]
     [:text
      {:class "footnote"
       :foreground "muted-foreground"
       :value (reactive base/flashcard-remaining-label model-source)}]]
   [:scroll
    {:grow 1.0}
    [:column
     {:accessibility-identifier "card.flashcard.question"
      :gap 18
      :padding 22
      :background "surface"
      :corner-radius 18}
     [:text
      {:class "title2 semibold"
       :value (reactive base/flashcard-question model-source)
       :accessibility-identifier "flashcard.question"}]
     [:if {:test (reactive base/flashcard-answer-rows-visible? model-source)}
      [:column
       {:gap 18}
       [:separator {:accessibility-identifier "flashcard.answer-divider"}]
       [:column
        {:gap 12}
        [:keyed
         {:source (reactive base/visible-flashcard-answer-rows model-source)
          :key base/flashcard-answer-identifier
          :compare compare
          :as answer-source}
         [flashcard-answer-row answer-source]]]]]]]
    [:if {:test (reactive base/flashcard-show-cloze? model-source)}
    [:row
     [:button
      {:variant "ghost"
       :class "semibold"
       :grow 1.0
       :min-height 50
       :text-alignment "center"
       :foreground "white"
       :background "primary"
       :corner-radius 14
       :accessibility-identifier "button.flashcard.show-cloze"
       :on-press (fn [_event] (send model/RevealFlashcardCloze))}
      "Show cloze"]]]
    [:if {:test (reactive base/flashcard-show-answer? model-source)}
    [:row
     [:button
      {:variant "ghost"
       :class "semibold"
       :grow 1.0
       :min-height 50
       :text-alignment "center"
       :foreground "white"
       :background "primary"
       :corner-radius 14
       :accessibility-identifier "button.flashcard.show-answer"
       :on-press (fn [_event] (send model/RevealFlashcardAnswer))}
      "Show answer"]]]
    [:if {:test (reactive base/flashcard-show-ratings? model-source)}
     [:column
      {:gap 10}
      [:row
       {:gap 10}
       [flashcard-rating-button
        "again" "Again" "red" "flashcard-again-background" send]
       [flashcard-rating-button
        "hard" "Hard" "warning-foreground" "flashcard-hard-background" send]]
      [:row
       {:gap 10}
       [flashcard-rating-button
        "good" "Good" "blue" "flashcard-good-background" send]
       [flashcard-rating-button
        "easy" "Easy" "green" "flashcard-easy-background" send]]]]]
   [:box
    {:height 24
     :accessibility-identifier "spacer.flashcards.bottom"}]])

(defui flashcard-screen [^:signal<model/chat-model> model-source send]
  [:column
   {:accessibility-identifier "screen.flashcards"
    :grow 1.0
    :gap 0
    :background "background"}
   [:if {:test (reactive base/flashcards-empty? model-source)}
    [:column
     {:accessibility-identifier "layout.flashcards.empty"
      :grow 1.0
      :main "center"
      :cross "center"
      :gap 10
      :padding 32}
     [:icon
      {:name "app:flashcards"
       :width 48
       :height 48
       :foreground "muted-foreground"}]
     [:heading
      {:level 3
       :accessibility-identifier "flashcards.empty"}
      "No cards due"]
     [:text
      {:text-alignment "center"
       :foreground "muted-foreground"}
      "Tag any block with #Card to review it here."]]]
   [:if {:test (reactive base/flashcards-present? model-source)}
    [flashcard-review-content model-source send]]])
