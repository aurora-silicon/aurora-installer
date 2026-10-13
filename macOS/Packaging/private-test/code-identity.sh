#!/bin/bash
# Native macOS code-directory identity helpers. Sourced by private packagers.
private_code_hash() {
  local details digest
  details=$(/usr/bin/codesign --display --verbose=4 "$1" 2>&1) || return 1
  digest=$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^CDHash=//p')
  [[ $digest =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$digest"
}

private_code_requirement() {
  local digest
  digest=$(private_code_hash "$1") || return 1
  printf 'identifier "%s" and cdhash H"%s"\n' "$2" "$digest"
}

# Both flags are authenticated bundle resources. Ambiguous/ordinary bundles are
# not accepted by this private installer path.
private_bundle_profile() {
  local app=$1 plain limine file
  plain=$(/usr/bin/plutil -extract OmarchyPrivatePlainTest raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)
  limine=$(/usr/bin/plutil -extract OmarchyPrivateLimineTest raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)
  if [[ $plain == "true" && $limine != "true" ]]; then
    echo plain
  elif [[ $limine == "true" && $plain != "true" ]]; then
    for file in catalog.json catalog.json.sig; do
      [[ -f $app/Contents/Resources/Release/$file && ! -L $app/Contents/Resources/Release/$file ]] || return 1
    done
    echo limine
  else
    echo 'An unambiguous private plain or Limine profile is required.' >&2
    return 1
  fi
}
