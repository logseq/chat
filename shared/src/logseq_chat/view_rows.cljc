(ns logseq-chat.view-rows
  (:require [logseq-chat.view-base :as base]))

(type-record retained-row
             (render-key :string)
             (value :model/outline-row)
             (is-editing :bool)
             (editing-title :string)
             (editing-caret :int))

(defn make-retained-outline-row [^model/chat-model current ^model/outline-row row]
  (match (:outliner-editing current)
    (Some editing)
    (if (= (:uuid editing) (:uuid row))
      (record retained-row
              (render-key "active-outliner-editor")
              (value row)
              (is-editing true)
              (editing-title (:title editing))
              (editing-caret (:caret-utf16-offset editing)))
      (record retained-row
              (render-key (:uuid row))
              (value row)
              (is-editing false)
              (editing-title "")
              (editing-caret 0)))
    None
    (record retained-row
            (render-key (:uuid row))
            (value row)
            (is-editing false)
            (editing-title "")
            (editing-caret 0))))

(defn retained-outliner-rows [^model/chat-model current]
  (mapv
   (fn [row] (make-retained-outline-row current row))
   (:outliner-rows current)))

(defn first-journal-section-visible? [^model/chat-model current]
  (and
   (base/journal-root-visible? current)
   (match (:selected-page current)
     None true
     (Some _page) false)
   (not (empty? (:outliner-section-markers current)))
   (= 0 (:start-index (nth (:outliner-section-markers current) 0)))))

(defn first-journal-section-identifier [^model/chat-model current]
  (if (first-journal-section-visible? current)
    (str "journal.section."
         (:page-id (nth (:outliner-section-markers current) 0)))
    "journal.section"))

(defn first-journal-retained-rows [^model/chat-model current]
  (if (first-journal-section-visible? current)
    (let [section (nth (:outliner-section-markers current) 0)]
      (mapv
       (fn [row] (make-retained-outline-row current row))
       (subvec (:outliner-rows current)
               (:start-index section)
               (:end-index section))))
    []))

(defn remaining-retained-outliner-rows [^model/chat-model current]
  (if (first-journal-section-visible? current)
    (let [section (nth (:outliner-section-markers current) 0)]
      (mapv
       (fn [row] (make-retained-outline-row current row))
       (subvec (:outliner-rows current) (:end-index section))))
    (retained-outliner-rows current)))

(defn retained-row-value [^retained-row retained] (:value retained))

(defn retained-row-identifier [^retained-row retained] (:render-key retained))

(defn retained-row-editing? [^retained-row retained] (:is-editing retained))

(defn retained-row-editing-title [^retained-row retained] (:editing-title retained))

(defn retained-row-editing-caret [^retained-row retained] (:editing-caret retained))
