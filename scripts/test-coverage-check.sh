#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/coverage-check-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

opam exec --switch=5.5.0 -- ocamlfind ocamlopt -w -24 \
  -package compiler-libs.common -c \
  -o "$tmp/check.cmx" -impl "$root/scripts/coverage_check.ml"
opam exec --switch=5.5.0 -- ocamlfind ocamlopt \
  -package compiler-libs.common -linkpkg -o "$tmp/check.exe" "$tmp/check.cmx"

printf 'let feature_one () = 1\nlet feature_test_fake () = 2\nlet other () = 3\n' > "$tmp/generated.ml"
# Only the first two points belong to production. The test and unrelated points
# are deliberately covered so accidentally including them changes the result.
printf 'BISECT-COVERAGE-4 1 12 generated.ml 4 4 20 30 60 4 1 0 1 1' > "$tmp/partial.coverage"
"$tmp/check.exe" "$tmp/generated.ml" generated.ml feature_ 5000 "$tmp/partial.coverage"
if "$tmp/check.exe" "$tmp/generated.ml" generated.ml feature_ 5001 "$tmp/partial.coverage"; then
  echo 'error: accepted coverage below the floor' >&2
  exit 1
fi
if "$tmp/check.exe" "$tmp/generated.ml" missing.ml feature_ 0 "$tmp/partial.coverage"; then
  echo 'error: accepted missing coverage' >&2
  exit 1
fi
if "$tmp/check.exe" "$tmp/generated.ml" generated.ml absent_ 0 "$tmp/partial.coverage"; then
  echo 'error: accepted missing production definitions' >&2
  exit 1
fi
printf 'BISECT-COVERAGE-4 1 12 generated.ml 1 4 0' > "$tmp/invalid.coverage"
if "$tmp/check.exe" "$tmp/generated.ml" generated.ml feature_ 0 "$tmp/invalid.coverage"; then
  echo 'error: accepted inconsistent point/count arrays' >&2
  exit 1
fi
printf 'BISECT-COVERAGE-4 1 12 generated.ml 1 30 1 1' > "$tmp/no-production.coverage"
if "$tmp/check.exe" "$tmp/generated.ml" generated.ml feature_ 0 "$tmp/no-production.coverage"; then
  echo 'error: accepted coverage containing only tests' >&2
  exit 1
fi
printf 'BISECT-COVERAGE-5' > "$tmp/version.coverage"
if "$tmp/check.exe" "$tmp/generated.ml" generated.ml feature_ 0 "$tmp/version.coverage"; then
  echo 'error: accepted an unsupported coverage format' >&2
  exit 1
fi
echo 'coverage checks passed'
