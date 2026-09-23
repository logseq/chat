let month_names =
  [ "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"; "Oct";
    "Nov"; "Dec" ]

let day_title journal_day =
  let year = journal_day / 10000 in
  let month = journal_day / 100 mod 100 in
  let day = journal_day mod 100 in
  let suffix =
    if 11 <= day && day <= 13 then "th"
    else match day mod 10 with 1 -> "st" | 2 -> "nd" | 3 -> "rd" | _ -> "th"
  in
  Printf.sprintf "%s %d%s, %04d" (List.nth month_names (month - 1)) day suffix
    year
