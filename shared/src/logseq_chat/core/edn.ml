let decode source =
  try Ok (Melange_edn_native.of_edn_string source)
  with
  | Melange_edn_native.Parse_error message -> Error message
  | Failure message -> Error message
  | Invalid_argument message -> Error message

let encode value = Melange_edn_native.to_edn_string value
