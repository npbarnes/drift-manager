# shellcheck shell=bash

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/common.sh"

rm_with_parents_if_empty() {
    # delete the file given as argument; then if it's parent directory is now empty, delete it; then if
    # it's grand parent directory is now empty, delete it; etc.
    local f="$1"

    rm "$f"
    rmdir --ignore-fail-on-non-empty --parents "$(dirname "$f")"
}

stash() {
    # Precondition: "$1" is an absolute path to a readable file (not directory) in the live directory
    # and "$2" is an absolute path to a writable directory
    # Postcondition: if "$1" is "$livedir/a/b/c" then it gets copied to "$2/a/b/c"

    local abspath="$1"
    local stashdir="$2"
    local livedir="$3"

    # Check that the args are absolute paths
    if [[ "$abspath" != /* ]] || [[ "$stashdir" != /* ]]; then
        echo "$abspath"
        echo "$stashdir"
        echo "Error ($LINENO): argument not an absolute path, stash() only operates on absolute paths." >&2
        exit 1
    fi

    # check that abs path is not a directory (if it's not a file, cp will fail below)
    if [[ -d "$abspath" ]]; then
        echo "Error ($LINENO): cannot stash directories, only stash individual files." >&2
        exit 2
    fi

    # check that stash is a directory
    if [[ ! -d "$stashdir" ]]; then
        echo "Error ($LINENO): the stash location must be a directory" >&2
        exit 3
    fi

    local relpath
    relpath="$(realpath --relative-to="$livedir" "$abspath")"

    # Check that abspath is in the home directory
    if [[ "$relpath" == ..* ]]; then
        echo "Error ($LINENO): Only files under the home directory can be stashed" >&2
        exit 4
    fi

    local folders
    local stashpath
    folders="$(dirname "$relpath")"
    stashpath="$stashdir/$folders"

    mkdir -p "$stashpath"
    cp --update=none-fail "$abspath" "$stashpath"
}

mark_deleted() {
    local abspath="$1"
    local deletedlistfile="$2"
    # TODO: track stash number
    echo "$abspath" >> "$deletedlistfile"
}

activate_file() {
    local gen="$1"
    local applied="$2"
    local live="$3"
    local stashdir="$4"
    local deletedlistfile="$5"
    local livedir="$6"

    if [ ! -f "$gen" ]; then
        echo "Error ($LINENO): \$gen must be a file" >&2
        exit 1
    fi

    if [ ! -f "$applied" ]; then
        if [ -f "$live" ] && ! cmp -s "$gen" "$live"; then
            stash "$live" "$stashdir" "$livedir"
        fi
    else
        if [ ! -f "$live" ]; then
            mark_deleted "$live" "$deletedlistfile"
        elif ! cmp -s "$applied" "$live" && ! cmp -s "$gen" "$live"; then
            stash "$live" "$stashdir" "$livedir"
        fi
    fi

    cp "$gen" "$applied"
    cp "$gen" "$live"
}

activate_each_file() {
    local -n _genfiles="$1"
    local -n _appliedfiles="$2"
    local -n _livefiles="$3"
    local stashdir="$4"
    local deletedlistfile="$5"
    local livedir="$6"

    local gen
    local applied
    local live

    for i in "${!_genfiles[@]}"; do  
        gen="${_genfiles[$i]}"
        applied="${_appliedfiles[$i]}"
        live="${_livefiles[$i]}"

        activate_file "$gen" "$applied" "$live" "$stashdir" "$deletedlistfile" "$livedir"
    done
}

check_all_genfiles_present_no_extras() {
    local gendir="$1"
    local -n _genfiles_expected="$2"

    # Convert genfiles array to a set for O(1) lookup
    local -A expected_set
    for f in "${_genfiles_expected[@]}"; do
        expected_set["$f"]=1
    done

    # convert the actual files to an array
    local -a gendir_files
    mapfile -d '' gendir_files < <(find "$gendir" -type f -print0)

    # Check same length
    if [[ "${#gendir_files[@]}" != "${#expected_set[@]}" ]]; then
        echo "Error ($LINENO): Unexpected State: the files in the generation folder do not exactly match this generation." >&2
        exit 1
    fi

    # Check all match
    for f in "${gendir_files[@]}"; do
        if [[ ! -v expected_set["$f"] ]]; then
            echo "Error ($LINENO): Unexpected State: the files in the generation folder do not exactly match this generation." >&2
            exit 1
        fi
    done

    return 0
}

check_tracking_lists_have_same_length() {
    local -n _genfiles="$1"
    local -n _appliedfiles="$2"
    local -n _livefiles="$3"

    # shellcheck disable=SC2055
    if [[ "${#_genfiles[@]}" != "${#_appliedfiles[@]}" || "${#_genfiles[@]}" != "${#_livefiles[@]}" || "${#_appliedfiles[@]}" != "${#_livefiles[@]}" ]]; then
        echo "Error ($LINENO): not all tracking lists (generation, applied, and live) are the same length" >&2
        exit 1
    fi

    return 0
}

check_entries() {
    local gendir="$1"
    local applieddir="$2"
    local livedir="$3"

    local genfiles_name="$4"
    local appliedfiles_name="$5"
    local livefiles_name="$6"

    local -n _genfiles="$4"
    local -n _appliedfiles="$5"
    local -n _livefiles="$6"

    local gen
    local applied
    local live

    local genrel
    local appliedrel
    local liverel

    check_tracking_lists_have_same_length "$genfiles_name" "$appliedfiles_name" "$livefiles_name"

    for i in "${!_genfiles[@]}"; do
        gen="${_genfiles[$i]}"
        applied="${_appliedfiles[$i]}"
        live="${_livefiles[$i]}"

        if [[ "$gen" != /* ]]; then
            echo "Error ($LINENO): generation file is not an absolute path" >&2
            exit 10
        fi
        if [[ "$applied" != /* ]]; then
            echo "Error ($LINENO): applied file is not an absolute path" >&2
            exit 11
        fi
        if [[ "$live" != /* ]]; then
            echo "Error ($LINENO): live file is not an absolute path" >&2
            exit 12
        fi

        check_valid_filename "$(basename "$gen")"
        check_valid_filename "$(basename "$applied")"
        check_valid_filename "$(basename "$live")"

        if [[ "$(dirname "$gen")" != "$gendir" ]]; then
            echo "Error ($LINENO): generation file is not located in the generation folder"
            exit 20
        fi
        if [[ "$(dirname "$applied")" != "$applieddir" ]]; then
            echo "Error ($LINENO): applied file is not located in the applied folder"
            exit 21
        fi 
        if [[ "$(dirname "$live")" != "$livedir" ]]; then
            echo "Error ($LINENO): live file $live is not located in the live folder $livedir."
            exit 22
        fi 

        genrel="$(realpath --relative-to="$gendir" "$gen")"
        appliedrel="$(realpath --relative-to="$applieddir" "$applied")"
        liverel="$(realpath --relative-to="$livedir" "$live")"

        if [[ "$genrel" == ..* ]]; then
            echo "Error ($LINENO): generation file found outside of generation directory." >&2
            exit 1
        fi
        if [[ "$appliedrel" == ..* ]]; then
            echo "Error ($LINENO): applied file found outside of applied directory." >&2
            exit 2
        fi
        if [[ "$liverel" == ..* ]]; then
            echo "Error ($LINENO): live file found outside of home directory." >&2
            exit 3
        fi

        # shellcheck disable=SC2055
        if [[ "$genrel" != "$appliedrel" || "$genrel" != "$liverel" || "$appliedrel" != "$liverel" ]]; then
            echo "Error ($LINENO): relative paths of the generation, applied, and live files are not identical." >&2
            exit 4
        fi
    done

    return 0
}

handle_untracked_applied() {
    local -n _appliedfiles="$1"
    local stashdir="$2"
    local livedir="$3"

    # Convert appliedfiles to a set for O(1) lookup
    local -A applied_set
    for f in "${_appliedfiles[@]}"; do
        applied_set["$f"]=1
    done
    
    # Collect untracked files in $applieddir
    local -a untracked=()
    shopt -s nullglob dotglob
    for f in "$applieddir"/*; do
        [[ -f "$f" ]] || continue
        if [[ ! -v applied_set["$f"] ]]; then
            untracked+=("$f")
        fi
    done
    shopt -u nullglob dotglob

    local rel
    local live_counterpart
    for f in "${untracked[@]}"; do
        rel="$(realpath --relative-to="$applieddir" "$f")"
        live_counterpart="$livedir/$rel"
        if [ -f "$live_counterpart" ]; then
            stash "$live_counterpart" "$stashdir" "$livedir"
            rm_with_parents_if_empty "$live_counterpart"
        fi
        rm_with_parents_if_empty "$f"
    done
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

        # Must be purely numeric
        if [[ ! "$name" =~ ^[0-9]+$ ]]; then
            echo "Error ($LINENO): '$name' is not a numeric directory name." >&2
            exit 1
        fi

        # Must have no leading zeros (except "0" itself, but 0 is not
        # a valid member of a 1-based sequence, so reject it too)
        if [[ "$name" =~ ^0 ]]; then
            echo "Error ($LINENO): '$name' has a leading zero (or is zero)." >&2
            exit 1
        fi

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
    mapfile -t sorted <<< "$sort_output"

    # --- Check for contiguous 1 … N ---
    local expected=1
    for num in "${sorted[@]}"; do
        if (( num != expected )); then
            if (( num < expected )); then
                echo "Error ($LINENO): Duplicate directory '$num'." >&2
            else
                echo "Error ($LINENO): Gap — expected '$expected' but found '$num'." >&2
            fi
            exit 1
        fi
        (( expected++ ))
    done

    # Return the highest number
    _highest="${sorted[-1]}"
    return 0
}

generate_numbered_stash() {
    local dir="$1"
    local -n _out="$2"

    if [[ ! -d "$dir" ]]; then
        echo "Error ($LINENO): '$dir' is not a valid directory." >&2
        return 1
    fi

    local highest
    validate_numbered_dir "$dir" highest

    if [ -d "$dir/$highest" ] && test -n "$(find "$dir/$highest" -maxdepth 0 -empty)" ; then
        _out="$dir/$highest"
        return 0
    fi

    local next="$(( highest + 1 ))"
    mkdir -- "$dir/$next"
    _out="$dir/$next"
    return 0
}

activate() {
    # pass in three directories and the names of three global arrays
    local stashparent="$1"
    local gendir="$2"
    local applieddir="$3"
    local liveparent="$4"
    
    # These are the lists of filenames for files under tracking this generation
    # Not necessarily the reflective of the contents of their cooresponding directories
    local genfiles_name="$5"
    local appliedfiles_name="$6"
    local livefiles_name="$7"

    local deletedlistfile="$stashparent/deletedlist.txt"
    touch "$deletedlistfile"

    check_is_directory "$stashparent"
    check_is_directory "$gendir"
    check_is_directory "$applieddir"
    check_is_directory "$liveparent"

    local stashdir
    generate_numbered_stash "$stashparent" stashdir
    check_is_directory "$stashdir"

    check_stash_empty "$stashdir"
    check_all_genfiles_present_no_extras "$gendir" "$genfiles_name"
    check_entries "$gendir" "$applieddir" "$liveparent" "$genfiles_name" "$appliedfiles_name" "$livefiles_name"

    handle_untracked_applied "$appliedfiles_name" "$stashdir" "$liveparent"

    activate_each_file "$genfiles_name" "$appliedfiles_name" "$livefiles_name" "$stashdir" "$deletedlistfile" "$liveparent"
}