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
mldoc_checkout="$repo_root/Vendor/mldoc"
mldoc_source="$source_root/mldoc-ios-build"
mldoc_patch="$repo_root/scripts/patches/mldoc-wrapped.patch"
datascript_revision=3e9bee227686ba8608fc3fb027c4ebe30961360f
persistent_set_revision=f95398e77a1a003f65ecf201c4aede961e52e929
melange_edn_revision=a1410a31b57b5e42f152357d0303635685501bc6
melange_transit_revision=898bc1418e8e6405f53d659209d932cddc6e3070
ptime_revision=fc8e8dab8f417558d882e6989b080d9f2100f8b6
yojson_revision=b2193e8e0c88c6501710d08b836b3219673383f3
mldoc_revision=bedae990097fff9251cde34e685bc3cec13c01a3
ocamlopt="$target_prefix/bin/ocamlopt.opt"
ocamldep="$target_prefix/bin/ocamldep.opt"
ocaml_version=$("$ocamlopt" -version)
host_prefix="$(dirname "$target_prefix")/host-$ocaml_version"
[[ -x $host_prefix/bin/ocamlc ]] || {
  echo "error: OCaml $ocaml_version host compiler is missing at $host_prefix" >&2
  exit 1
}
opam_switch=5.5.0
[[ $ocaml_version == "$opam_switch" ]] || {
  echo "error: mobile dependencies require OCaml $opam_switch, got $ocaml_version" >&2
  exit 1
}
opam_prefix=$(opam var --switch="$opam_switch" prefix)
opam_sources="$opam_prefix/.opam-switch/sources"
host_dependency_lib="$opam_prefix/lib"
source_dir="$build_dir/mobile-ocaml-deps-source"
object_dir="$build_dir/mobile-ocaml-deps"
cache_stamp="$object_dir/.build-fingerprint"

build_fingerprint=$(
  {
    printf '%s\n' \
      "$datascript_revision" \
      "$persistent_set_revision" \
      "$melange_edn_revision" \
      "$melange_transit_revision" \
      "$ptime_revision" \
      "$yojson_revision" \
      "$mldoc_revision"
    "$ocamlopt" -version
    "$ocamlopt" -config
    shasum -a 256 "$repo_root/scripts/build-mobile-ocaml-deps.sh"
    shasum -a 256 "$mldoc_patch"
  } | shasum -a 256 | cut -d ' ' -f 1
)

if [[ -f $cache_stamp \
  && $(<"$cache_stamp") == "$build_fingerprint" \
  && -s $object_dir/link-objects.txt \
  && -s $object_dir/sqlite-stub-source.txt ]]; then
  echo "OCaml dependency cache hit: $object_dir"
  exit 0
fi

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

[[ -f $mldoc_checkout/lib/dune ]] || {
  echo "error: initialize the pinned Vendor/mldoc submodule" >&2
  exit 1
}
[[ $(git -C "$mldoc_checkout" rev-parse HEAD) == "$mldoc_revision" ]] || {
  echo "error: Vendor/mldoc must be pinned at $mldoc_revision" >&2
  exit 1
}
rm -rf "$mldoc_source"
mkdir -p "$mldoc_source"
git -C "$mldoc_checkout" archive "$mldoc_revision" | tar -x -C "$mldoc_source"
/usr/bin/patch -d "$mldoc_source" -p1 <"$mldoc_patch"
opam exec --switch="$opam_switch" -- \
  dune build --root "$mldoc_source" lib/mldoc.cmxa

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

PATH="$host_prefix/bin:$PATH" dune build --root "$yojson_source" lib/yojson.cmxa
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
"$ocamlopt" -I "$object_dir" -c \
  -o datascript_sqlite_codec.cmx \
  "$datascript_source/sqlite/datascript_sqlite_codec.ml"

bigstringaf_source="$opam_sources/bigstringaf.0.10.0/lib"
stringext_source="$opam_sources/stringext.1.6.0/lib"
uri_source="$opam_sources/uri.4.4.0/lib"
ppx_deriving_source="$opam_sources/ppx_deriving.6.1.3/src/runtime"
ppx_yojson_source="$opam_sources/ppx_deriving_yojson.3.10.0/src"
angstrom_source="$host_dependency_lib/angstrom"
xmlm_source="$opam_sources/xmlm/src"

"$ocamlopt" -I "$object_dir" -c "$bigstringaf_source/bigstringaf.mli" \
  -o bigstringaf.cmi
"$ocamlopt" -I "$object_dir" -c "$bigstringaf_source/bigstringaf.ml" \
  -o bigstringaf.cmx
"$ocamlopt" -c "$bigstringaf_source/bigstringaf_stubs.c" \
  -o bigstringaf_stubs.o
"$ocamlopt" -I "$object_dir" -c "$ppx_deriving_source/ppx_deriving_runtime.mli" \
  -o ppx_deriving_runtime.cmi
"$ocamlopt" -I "$object_dir" -c "$ppx_deriving_source/ppx_deriving_runtime.ml" \
  -o ppx_deriving_runtime.cmx
"$ocamlopt" -I "$object_dir" -c "$ppx_yojson_source/ppx_deriving_yojson_runtime.mli" \
  -o ppx_deriving_yojson_runtime.cmi
"$ocamlopt" -I "$object_dir" -c "$ppx_yojson_source/ppx_deriving_yojson_runtime.ml" \
  -o ppx_deriving_yojson_runtime.cmx
"$ocamlopt" -I "$object_dir" -c "$stringext_source/stringext.mli" \
  -o stringext.cmi
"$ocamlopt" -I "$object_dir" -c "$stringext_source/stringext.ml" \
  -o stringext.cmx

"$ocamlopt" -I "$object_dir" -no-alias-deps -w -49 -c \
  "$angstrom_source/angstrom__.ml" -o angstrom__.cmx
for module in Input Buffering More Exported_state Parser; do
  source_name=$(printf '%s' "$module" | tr '[:upper:]' '[:lower:]')
  if [[ -f $angstrom_source/$source_name.mli ]]; then
    "$ocamlopt" -I "$object_dir" -open Angstrom__ -c \
      "$angstrom_source/$source_name.mli" -o "angstrom__${module}.cmi"
  fi
  "$ocamlopt" -I "$object_dir" -open Angstrom__ -c \
    "$angstrom_source/$source_name.ml" -o "angstrom__${module}.cmx"
done
"$ocamlopt" -I "$object_dir" -open Angstrom__ -c \
  "$angstrom_source/angstrom.mli" -o angstrom.cmi
"$ocamlopt" -I "$object_dir" -open Angstrom__ -c \
  "$angstrom_source/angstrom.ml" -o angstrom.cmx
"$ocamlopt" -I "$object_dir" -c "$uri_source/uri.mli" -o uri.cmi
"$ocamlopt" -I "$object_dir" -c "$uri_source/uri.ml" -o uri.cmx
"$ocamlopt" -I "$object_dir" -c "$xmlm_source/xmlm.mli" -o xmlm.cmi
"$ocamlopt" -I "$object_dir" -c "$xmlm_source/xmlm.ml" -o xmlm.cmx

mldoc_build="$mldoc_source/_build/default/lib"
"$ocamlopt" -I "$object_dir" -no-alias-deps -w -49 -c \
  -impl "$mldoc_build/mldoc__.ml-gen" -o mldoc__.cmx
mldoc_sources=$(find "$mldoc_build" -type f -name '*.pp.ml' \
  ! -path "$mldoc_build/mldoc.pp.ml" -print | sort -u)
mldoc_ordered=$(opam exec --switch="$opam_switch" -- ocamldep -sort $mldoc_sources)
mldoc_seen=' '
: >"$object_dir/mldoc-link-objects.txt"
for source in $mldoc_ordered; do
  source_name=$(basename "$source" .pp.ml)
  case "$mldoc_seen" in
    *" $source_name "*) continue ;;
  esac
  mldoc_seen="$mldoc_seen$source_name "
  module_name="${source_name^}"
  interface="$(dirname "$source")/$source_name.pp.mli"
  if [[ -f $interface ]]; then
    "$ocamlopt" -I "$object_dir" -open Mldoc__ -c "$interface" \
      -o "mldoc__${module_name}.cmi"
  fi
  "$ocamlopt" -I "$object_dir" -open Mldoc__ -c "$source" \
    -o "mldoc__${module_name}.cmx"
  printf '%s\n' "$object_dir/mldoc__${module_name}.cmx" \
    >>"$object_dir/mldoc-link-objects.txt"
done
"$ocamlopt" -I "$object_dir" -open Mldoc__ -c "$mldoc_build/mldoc.pp.ml" \
  -o mldoc.cmx

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
  transit_native.cmx \
  datascript_sqlite_codec.cmx; do
  printf '%s\n' "$object_dir/$object" >>"$object_dir/link-objects.txt"
done
for object in \
  bigstringaf.cmx \
  bigstringaf_stubs.o \
  ppx_deriving_runtime.cmx \
  ppx_deriving_yojson_runtime.cmx \
  angstrom__.cmx \
  angstrom__Input.cmx \
  angstrom__Buffering.cmx \
  angstrom__More.cmx \
  angstrom__Exported_state.cmx \
  angstrom__Parser.cmx \
  angstrom.cmx \
  stringext.cmx \
  uri.cmx \
  xmlm.cmx \
  mldoc__.cmx; do
  printf '%s\n' "$object_dir/$object" >>"$object_dir/link-objects.txt"
done
while IFS= read -r object; do
  printf '%s\n' "$object" >>"$object_dir/link-objects.txt"
done <"$object_dir/mldoc-link-objects.txt"
printf '%s\n' "$object_dir/mldoc.cmx" >>"$object_dir/link-objects.txt"

printf '%s\n' "$datascript_source/sqlite/datascript_sqlite_stubs.c" \
  >"$object_dir/sqlite-stub-source.txt"
printf '%s\n' "$build_fingerprint" >"$cache_stamp"
