#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 TARGET_PREFIX BUILD_DIRECTORY" >&2
  exit 2
fi

target_prefix=$(cd "$1" && pwd)
mkdir -p "$2"
build_dir=$(cd "$2" && pwd)
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root="$repo_root/_build/mobile-dependency-sources"
datascript_source="$source_root/datascript-ocaml"
persistent_set_source="$source_root/persistent-sorted-set-ocaml"
melange_edn_source="$source_root/melange-edn"
melange_transit_source="$source_root/melange-transit"
ptime_source="$source_root/ptime"
yojson_source="$source_root/yojson"
datascript_revision=3e9bee227686ba8608fc3fb027c4ebe30961360f
persistent_set_revision=f95398e77a1a003f65ecf201c4aede961e52e929
melange_edn_revision=a1410a31b57b5e42f152357d0303635685501bc6
melange_transit_revision=898bc1418e8e6405f53d659209d932cddc6e3070
ptime_revision=fc8e8dab8f417558d882e6989b080d9f2100f8b6
yojson_revision=b2193e8e0c88c6501710d08b836b3219673383f3
ocamlopt="$target_prefix/bin/ocamlopt.opt"
ocamldep="$target_prefix/bin/ocamldep.opt"
source_dir="$build_dir/mobile-ocaml-deps-source"
object_dir="$build_dir/mobile-ocaml-deps"

clone_revision() {
  local url=$1
  local revision=$2
  local destination=$3

  if [[ ! -d $destination/.git ]]; then
    git clone "$url" "$destination"
  fi
  git -C "$destination" remote set-url origin "$url"
  git -C "$destination" fetch origin "$revision"
  git -C "$destination" checkout --detach "$revision"
}

clone_revision \
  https://github.com/logseq/datascript-ocaml.git \
  "$datascript_revision" \
  "$datascript_source"
clone_revision \
  https://github.com/logseq/persistent-sorted-set-ocaml.git \
  "$persistent_set_revision" \
  "$persistent_set_source"
clone_revision \
  https://github.com/RCmerci/melange-edn.git \
  "$melange_edn_revision" \
  "$melange_edn_source"
clone_revision \
  https://github.com/tiensonqin/melange-transit.git \
  "$melange_transit_revision" \
  "$melange_transit_source"
clone_revision \
  https://github.com/dbuenzli/ptime.git \
  "$ptime_revision" \
  "$ptime_source"
clone_revision \
  https://github.com/ocaml-community/yojson.git \
  "$yojson_revision" \
  "$yojson_source"

mkdir -p "$source_dir" "$object_dir"

ln -sf \
  "$persistent_set_source/lib/persistent_sorted_set.mli" \
  "$source_dir/persistent_sorted_set.mli"
ln -sf \
  "$persistent_set_source/lib/persistent_sorted_set.ml" \
  "$source_dir/persistent_sorted_set.ml"
ln -sf \
  "$persistent_set_source/lib/platform_weak_slot.mli" \
  "$source_dir/platform_weak_slot.mli"
ln -sf \
  "$persistent_set_source/lib/platform/native/platform_weak_slot.ml" \
  "$source_dir/platform_weak_slot.ml"
ln -sf \
  "$datascript_source/type/datascript_types.ml" \
  "$source_dir/datascript_types.ml"
ln -sf \
  "$datascript_source/impl/platform.mli" \
  "$source_dir/platform.mli"
ln -sf \
  "$datascript_source/impl/platform/native/platform.ml" \
  "$source_dir/platform.ml"

for source in "$datascript_source"/impl/*.ml "$datascript_source"/impl/*.mli; do
  ln -sf "$source" "$source_dir/$(basename "$source")"
done

cd "$source_dir"
ordered_sources=$("$ocamldep" -sort ./*.mli ./*.ml)

cd "$object_dir"
for source in $ordered_sources; do
  source_path="$source_dir/${source#./}"
  module_name=$(basename "$source")
  case "$source" in
    *.mli)
      "$ocamlopt" -I "$object_dir" -c "$source_path" \
        -o "${module_name%.mli}.cmi"
      ;;
    *.ml)
      "$ocamlopt" -I "$object_dir" -c "$source_path" \
        -o "${module_name%.ml}.cmx"
      ;;
  esac
done

dune build --root "$yojson_source" lib/yojson.cmxa
yojson_lib="$yojson_source/_build/default/lib"
ln -sf "$yojson_lib/yojson__.ml-gen" "$source_dir/yojson__.ml"
"$ocamlopt" -I "$object_dir" -no-alias-deps -w -49 -c \
  -o yojson__.cmx "$source_dir/yojson__.ml"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Codec.cmi "$yojson_lib/codec.mli"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Codec.cmx "$yojson_lib/codec.ml"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Common.cmi "$yojson_lib/common.mli"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Common.cmx "$yojson_lib/common.ml"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Lexer_utils.cmx "$yojson_lib/lexer_utils.ml"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__T.cmi "$yojson_lib/t.mli"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__T.cmx "$yojson_lib/t.ml"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Basic.cmi "$yojson_lib/basic.mli"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Basic.cmx "$yojson_lib/basic.ml"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Raw.cmi "$yojson_lib/raw.mli"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Raw.cmx "$yojson_lib/raw.ml"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Safe.cmi "$yojson_lib/safe.mli"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson__Safe.cmx "$yojson_lib/safe.ml"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson.cmi "$yojson_lib/yojson.mli"
"$ocamlopt" -I "$object_dir" -open Yojson__ -c \
  -o yojson.cmx "$yojson_lib/yojson.ml"

"$ocamlopt" -I "$object_dir" -c \
  -o ptime.cmi "$ptime_source/src/ptime.mli"
"$ocamlopt" -I "$object_dir" -c \
  -o ptime.cmx "$ptime_source/src/ptime.ml"

"$ocamlopt" -I "$object_dir" -c \
  -o melange_edn.cmi "$melange_edn_source/lib/melange_edn.mli"
"$ocamlopt" -I "$object_dir" -c \
  -o melange_edn.cmx "$melange_edn_source/lib/melange_edn.ml"
"$ocamlopt" -I "$object_dir" -c \
  -o melange_edn_native.cmi \
  "$melange_edn_source/lib_native/melange_edn_native.mli"
"$ocamlopt" -I "$object_dir" -c \
  -o melange_edn_native.cmx \
  "$melange_edn_source/lib_native/melange_edn_native.ml"

"$ocamlopt" -I "$object_dir" -c \
  -o transit_core.cmi "$melange_transit_source/lib/common/transit_core.mli"
"$ocamlopt" -I "$object_dir" -c \
  -o transit_core.cmx "$melange_transit_source/lib/common/transit_core.ml"
"$ocamlopt" -I "$object_dir" -c \
  -o transit_edn.cmi "$melange_transit_source/lib/shared/transit_edn.mli"
"$ocamlopt" -I "$object_dir" -c \
  -o transit_edn.cmx "$melange_transit_source/lib/shared/transit_edn.ml"
"$ocamlopt" -I "$object_dir" -c \
  -o transit.cmi "$melange_transit_source/lib/native/transit.mli"
"$ocamlopt" -I "$object_dir" -c \
  -o transit.cmx "$melange_transit_source/lib/native/transit.ml"
printf '%s\n' \
  'module Transit = Transit' \
  'module Transit_edn = Transit_edn' \
  >"$source_dir/transit_native.ml"
"$ocamlopt" -I "$object_dir" -c \
  -o transit_native.cmx "$source_dir/transit_native.ml"

cmx_list=$("$ocamldep" -sort "$source_dir"/*.ml)
: >"$object_dir/link-objects.txt"
for source in $cmx_list; do
  case "$source" in
    */yojson__.ml | */transit_native.ml) continue ;;
  esac
  printf '%s\n' "$object_dir/$(basename "${source%.ml}.cmx")" \
    >>"$object_dir/link-objects.txt"
done
for object in \
  yojson__.cmx \
  yojson__Codec.cmx \
  yojson__Common.cmx \
  yojson__Lexer_utils.cmx \
  yojson__T.cmx \
  yojson__Basic.cmx \
  yojson__Raw.cmx \
  yojson__Safe.cmx \
  yojson.cmx \
  ptime.cmx \
  melange_edn.cmx \
  melange_edn_native.cmx \
  transit_core.cmx \
  transit_edn.cmx \
  transit.cmx \
  transit_native.cmx; do
  printf '%s\n' "$object_dir/$object" >>"$object_dir/link-objects.txt"
done

printf '%s\n' "$datascript_source/sqlite/datascript_sqlite_stubs.c" \
  >"$object_dir/sqlite-stub-source.txt"
