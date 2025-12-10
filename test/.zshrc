cds() {
  local raw target_path commands cmds_part

  raw=$(command cds "$@" 2>&1 1>/dev/tty)

  if [[ "$raw" == CDS_RESULT:* ]]; then
    raw="${raw#CDS_RESULT:}"
    if [[ "$raw" == *"|CDS_COMMANDS|"* ]]; then
      target_path=${raw%%"|CDS_COMMANDS|"*}
      cmds_part=${raw#*"|CDS_COMMANDS|"}
      commands=$(printf '%s' "$cmds_part" | sed 's/|CDS_SEP|/;/g')
    else
      target_path="$raw"
      commands=""
    fi

    target_path=$(printf '%s' "$target_path" | tr -d '\r')
    builtin cd "$target_path"

    if [[ -n "$commands" ]]; then
      IFS=';' read -rA cmds <<< "$commands"
      for cmd in "${cmds[@]}"; do
        [[ -n "$cmd" ]] && {
          echo "Executing: $cmd"
          [[ "$cmd" == "nix-shell" ]] && exec $cmd || eval "$cmd"
        }
      done
    fi
  fi
}
