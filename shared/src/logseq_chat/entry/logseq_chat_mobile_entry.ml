let () =
  if not (Native_bridge.linked ()) then
    failwith "OCaml/LUI native bridge failed to link";
  Mobile_session.start Native_crypto.call_raw
