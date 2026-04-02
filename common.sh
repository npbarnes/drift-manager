# shellcheck shell=bash

collect_dir_contents_array() {
  if [[ ! -d "$1" ]]; then
    echo "Error: '$1' is not a valid directory." >&2
    return 1
  fi

  local __cdc_dir="$1"
  local -n __cdc_out_ref="$2"

  # 3. Save the current state of the shell options
  local __cdc_saved_shopt
  __cdc_saved_shopt="$(shopt -p nullglob dotglob)"

  # Enable required options
  shopt -s nullglob dotglob

  # Populate the array
  __cdc_out_ref=("$__cdc_dir"/*)

  # 4. Restore the exact previous state of the shell options
  eval "$__cdc_saved_shopt"
}

check_is_directory() {
  if [ ! -d "$1" ]; then
    echo "Error ($LINENO): $1 is not a directory" >&2
    exit 1
  fi
}

check_valid_filename() {
  local name="${1:-}"

  # Must not be empty
  if [[ -z "$name" ]]; then
    echo "Error ($LINENO): invalid filename" >&2
    exit 1
  fi

  # Must not contain a slash
  if [[ "$name" == */* ]]; then
    echo "Error ($LINENO): invalid filename" >&2
    exit 1
  fi

  # Must not be . or ..
  if [[ "$name" == "." || "$name" == ".." ]]; then
    echo "Error ($LINENO): invalid filename" >&2
    exit 1
  fi

  # Must not exceed filesystem name limit (typically 255 bytes)
  if ((${#name} > 255)); then
    echo "Error ($LINENO): invalid filename" >&2
    exit 1
  fi

  return 0
}

is_empty() {
  # Returns success if the given file or directory is empty. The given path must point to
  # either a file or directory that actually exists.
  local arg="$1"

  if [ -d "$arg" ]; then
    if test -n "$(find "$arg" -maxdepth 0 -empty)"; then
      return 0
    else
      return 1
    fi
  elif [ -s "$arg" ]; then
    return 1
  elif [ -f "$arg" ]; then
    return 0
  else
    echo "Error ($LINENO): is_empty expected either an existing file or existing directory." >&2
    exit 1
  fi
}

is_well_formed_number() {
  local name="$1"

  # Must be purely numeric
  if [[ ! "$name" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  # Must have no leading zeros (except "0" itself, but 0 is not
  # a valid member of a 1-based sequence, so reject it too)
  if [[ "$name" =~ ^0 ]]; then
    return 2
  fi

  return 0
}

check_well_formed_number() {
  if ! is_well_formed_number "$1"; then
    echo "Error ($LINENO): '$1' is not a positive integer." >&2
    exit 1
  fi
}

is_empty_stash() {
  # A (numbered) stash is empty if the directory is empty, or both conflicts and deletedfiles
  # are empty
  local dir="$1"

  # Ensure the provided argument is a valid directory
  [[ -d "$dir" ]] || return 1

  local n
  n="$(basename "$dir")"
  if ! is_well_formed_number "$n"; then
    return 1
  fi

  local -a items
  collect_dir_contents_array "$dir" items

  local count=${#items[@]}

  # If the directory is empty, it's a success
  ((count == 0)) && return 0

  # If there are more than 2 items, there is definitely something extra
  ((count > 2)) && return 1

  # Evaluate the 1 or 2 items present
  for item in "${items[@]}"; do
    # Extract just the file/directory name without the path
    local basename="${item##*/}"

    if [[ "$basename" == "conflicts" ]]; then
      if [[ ! -d "$item" ]] || ! is_empty "$item"; then
        return 1
      fi
    elif [[ "$basename" == "deletedlist.txt" ]]; then
      if [[ ! -f "$item" ]] || ! is_empty "$item"; then
        return 1
      fi
    else
      return 1
    fi
  done

  # If the loop finishes without exiting, all constraints were met
  return 0
}

check_no_stashes() {
  local stashparent="$1"

  if is_empty "$stashparent"; then
    return 0
  fi

  local -a items
  collect_dir_contents_array "$stashparent" items

  if [ "${#items[@]}" -gt 1 ] || ! is_empty_stash "$items"; then
    echo "Error ($LINENO): stash is not empty" >&2
    exit 1
  fi

  if [ "$(basename "$items")" != "1" ]; then
    echo "Error: ($LINENO): Unexpected entry, $items, in stash." >&2
    exit 2
  fi

  return 0
}

validate_numbered_dir() {
  local dir="$1"
  local -n _highest="$2"

  if [[ ! -d "$dir" ]]; then
    echo "Error ($LINENO): '$dir' is not a valid directory." >&2
    exit 1
  fi

  # --- Collect every entry (files, dirs, symlinks, etc.) ---
  local entries=()
  while IFS= read -r -d '' entry; do
    entries+=("$entry")
  done < <(find "$dir" -maxdepth 1 -mindepth 1 -print0)

  local numbered_dirs=()

  for entry in "${entries[@]}"; do
    local name
    name="$(basename "$entry")"

    if [[ "$name" == "deletedlist.txt" ]]; then
      continue
    fi

    # Must be a directory (not a file, symlink-to-file, etc.)
    if [[ ! -d "$entry" ]]; then
      echo "Error ($LINENO): '$name' is not a directory." >&2
      exit 1
    fi

    check_well_formed_number "$name"

    numbered_dirs+=("$name")
  done

  # Empty directory is valid — highest number is 0
  if [[ ${#numbered_dirs[@]} -eq 0 ]]; then
    _highest="0"
    return 0
  fi

  # --- Sort numerically ---
  local sort_output
  if ! sort_output="$(printf '%s\n' "${numbered_dirs[@]}" | sort -n)"; then
    echo "Error ($LINENO): Failed to sort directory names." >&2
    exit 1
  fi

  local sorted
  mapfile -t sorted <<<"$sort_output"

  # --- Check for contiguous 1 … N ---
  local expected=1
  for num in "${sorted[@]}"; do
    if ((num != expected)); then
      if ((num < expected)); then
        echo "Error ($LINENO): Duplicate directory '$num'." >&2
      else
        echo "Error ($LINENO): Gap — expected '$expected' but found '$num'." >&2
      fi
      exit 1
    fi
    ((expected++))
  done

  # Return the highest number
  _highest="${sorted[-1]}"
  return 0
}
