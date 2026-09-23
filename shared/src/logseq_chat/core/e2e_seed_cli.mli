(** `logseq_chat_e2e_seed` CLI driver: parses arguments, seeds a local
    graph sqlite store, and reports the seeded graph's summary. *)

type seed_mode =
  | Inspect
  | Header_navigation
  | Composer
  | Outliner
  | Fixture
  | Performance
  | Default

val usage : string
val parse_args : string list -> (string * seed_mode, int * string) result
val now_ms : unit -> int
val seed_mode : Datascript.conn -> seed_mode -> (unit, string) result
val execute : string -> seed_mode -> (string, string) result
val run : string list -> int * string
