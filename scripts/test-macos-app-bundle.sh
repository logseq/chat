#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_dir=${LOGSEQ_CHAT_MACOS_APP_DIR:-$repo_root/.build/macos/LogseqChat.app}
executable="$app_dir/Contents/MacOS/LogseqChat"
resource_bundle="$app_dir/Contents/Resources/logseq-chat_LogseqChat.bundle"
compiled_assets="$resource_bundle/Contents/Resources/Assets.car"

[[ -x $executable ]] || {
  echo "error: macOS app executable was not found: $executable" >&2
  exit 1
}

[[ -f $compiled_assets ]] || {
  echo "error: compiled macOS icon assets were not found: $compiled_assets" >&2
  exit 1
}

loaded_icons=$(swift -e '
  import AppKit
  let bundle = Bundle(path: CommandLine.arguments[1])!
  for name in ["more_horiz", "task_todo", "plus", "arrow_upward"] {
    print("\(name)=\(bundle.image(forResource: NSImage.Name(name)) != nil)")
  }
' "$resource_bundle")
for icon in more_horiz task_todo plus arrow_upward; do
  [[ $loaded_icons == *"$icon=true"* ]] || {
    echo "error: macOS could not load icon from resource bundle: $icon" >&2
    exit 1
  }
done

mach_o_files=("$executable")
while IFS= read -r framework_binary; do
  mach_o_files+=("$framework_binary")
done < <(find "$app_dir/Contents/Frameworks" -type f -perm -111 2>/dev/null)

symbols=$(nm -gU "${mach_o_files[@]}")

[[ $symbols == *'_logseq_chat_call'* ]] || {
  echo "error: macOS app does not link logseq_chat_call" >&2
  exit 1
}

[[ $symbols == *'_caml_startup'* ]] || {
  echo "error: macOS app does not link the OCaml runtime" >&2
  exit 1
}

echo "ok - native OCaml core is linked"
