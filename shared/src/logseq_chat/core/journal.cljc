(ns logseq-chat.journal)

(def month-names ["Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"])

(defn day-title [journal-day]
  (let [year (quot journal-day 10000)
        month (mod (quot journal-day 100) 100)
        day (mod journal-day 100)
        suffix (if (<= 11 day 13)
                 "th"
                 (case (mod day 10) 1 "st" 2 "nd" 3 "rd" "th"))]
    (format "%s %d%s, %04d" (nth month-names (dec month)) day suffix year)))
