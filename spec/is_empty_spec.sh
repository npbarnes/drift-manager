# spec/is_empty_spec.sh

Describe 'is_empty()'
  Include "common.sh"

  # ---------- Setup / Teardown ----------
  setup() {
    TEST_DIR="$(mktemp -d)"
  }

  cleanup() {
    rm -rf "$TEST_DIR"
  }

  BeforeEach 'setup'
  AfterEach 'cleanup'

  # ======================================
  # Common Cases: Files
  # ======================================
  Describe 'with regular files'
    It 'returns success for an empty file'
      touch "$TEST_DIR/empty_file"
      When call is_empty "$TEST_DIR/empty_file"
      The status should be success
      The stderr should not be present
    End

    It 'returns 1 for a non-empty file'
      echo "hello world" > "$TEST_DIR/non_empty_file"
      When call is_empty "$TEST_DIR/non_empty_file"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns 1 for a file with a single character'
      printf 'x' > "$TEST_DIR/single_char"
      When call is_empty "$TEST_DIR/single_char"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns 1 for a file with a single newline'
      printf '\n' > "$TEST_DIR/newline_only"
      When call is_empty "$TEST_DIR/newline_only"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns 1 for a file with only whitespace'
      printf '   \t\t\n\n' > "$TEST_DIR/whitespace_only"
      When call is_empty "$TEST_DIR/whitespace_only"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns 1 for a file with a single null byte'
      printf '\0' > "$TEST_DIR/null_byte"
      When call is_empty "$TEST_DIR/null_byte"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns success for a file truncated to zero bytes'
      echo "some content" > "$TEST_DIR/truncated"
      truncate -s 0 "$TEST_DIR/truncated"
      When call is_empty "$TEST_DIR/truncated"
      The status should be success
      The stderr should not be present
    End
  End

  # ======================================
  # Common Cases: Directories
  # ======================================
  Describe 'with directories'
    It 'returns success for an empty directory'
      mkdir "$TEST_DIR/empty_dir"
      When call is_empty "$TEST_DIR/empty_dir"
      The status should be success
      The stderr should not be present
    End

    It 'returns 1 for a directory with a file'
      mkdir "$TEST_DIR/non_empty_dir"
      touch "$TEST_DIR/non_empty_dir/file.txt"
      When call is_empty "$TEST_DIR/non_empty_dir"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns 1 for a directory with a subdirectory'
      mkdir -p "$TEST_DIR/parent/child"
      When call is_empty "$TEST_DIR/parent"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns 1 for a directory containing only hidden files'
      mkdir "$TEST_DIR/dotfiles_dir"
      touch "$TEST_DIR/dotfiles_dir/.hidden"
      When call is_empty "$TEST_DIR/dotfiles_dir"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns 1 for a directory with multiple entries'
      mkdir "$TEST_DIR/multi_dir"
      touch "$TEST_DIR/multi_dir/a" "$TEST_DIR/multi_dir/b" "$TEST_DIR/multi_dir/c"
      When call is_empty "$TEST_DIR/multi_dir"
      The status should equal 1
      The stderr should not be present
    End
  End

  # ======================================
  # Edge Cases: Symlinks
  # ======================================
  Describe 'with symbolic links'
    It 'returns success for a symlink pointing to an empty file'
      touch "$TEST_DIR/empty_target"
      ln -s "$TEST_DIR/empty_target" "$TEST_DIR/link_to_empty"
      When call is_empty "$TEST_DIR/link_to_empty"
      The status should be success
      The stderr should not be present
    End

    It 'returns 1 for a symlink pointing to a non-empty file'
      echo "data" > "$TEST_DIR/non_empty_target"
      ln -s "$TEST_DIR/non_empty_target" "$TEST_DIR/link_to_non_empty"
      When call is_empty "$TEST_DIR/link_to_non_empty"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns success for a symlink pointing to an empty directory'
      mkdir "$TEST_DIR/empty_dir_target"
      ln -s "$TEST_DIR/empty_dir_target" "$TEST_DIR/link_to_empty_dir"
      When call is_empty "$TEST_DIR/link_to_empty_dir"
      The status should be success
      The stderr should not be present
    End

    It 'returns 1 for a symlink pointing to a non-empty directory'
      mkdir "$TEST_DIR/non_empty_dir_target"
      touch "$TEST_DIR/non_empty_dir_target/file"
      ln -s "$TEST_DIR/non_empty_dir_target" "$TEST_DIR/link_to_non_empty_dir"
      When call is_empty "$TEST_DIR/link_to_non_empty_dir"
      The status should be failure
      The stderr should not be present
    End
  End

  # ======================================
  # Edge Cases: Paths with Special Characters
  # ======================================
  Describe 'with special characters in paths'
    It 'handles filenames with spaces'
      touch "$TEST_DIR/file with spaces"
      When call is_empty "$TEST_DIR/file with spaces"
      The status should be success
      The stderr should not be present
    End

    It 'handles filenames with special characters'
      touch "$TEST_DIR/file@#\$%&!"
      When call is_empty "$TEST_DIR/file@#\$%&!"
      The status should be success
      The stderr should not be present
    End

    It 'handles filenames starting with a hyphen'
      touch "$TEST_DIR/-hyphen-file"
      When call is_empty "$TEST_DIR/-hyphen-file"
      The status should be success
      The stderr should not be present
    End

    It 'handles directory names with spaces'
      mkdir "$TEST_DIR/dir with spaces"
      When call is_empty "$TEST_DIR/dir with spaces"
      The status should be success
      The stderr should not be present
    End
  End

  # ======================================
  # Error Handling: Invalid Input
  # ======================================
  Describe 'with invalid input'
    It 'returns 2 for a non-existent path'
      When call is_empty "$TEST_DIR/does_not_exist"
      The status should equal 2
      The stderr should not be present
    End

    It 'returns 2 when called with no arguments'
      When call is_empty
      The status should equal 2
      The stderr should not be present
    End

    It 'returns 2 when given an empty string argument'
      When call is_empty ""
      The status should equal 2
      The stderr should not be present
    End

    It 'returns 2 for a broken symlink'
      ln -s "$TEST_DIR/nonexistent_target" "$TEST_DIR/broken_link"
      When call is_empty "$TEST_DIR/broken_link"
      The status should equal 2
      The stderr should not be present
    End
  End

  # ======================================
  # Error Handling: Permissions
  # ======================================
  Describe 'with permission issues'
    # Skip these tests if running as root (root bypasses permissions)
    Skip if 'running as root' test "$(id -u)" -eq 0

    It 'returns success for an unreadable, empty file'
      touch "$TEST_DIR/no_read_file"
      chmod a-r "$TEST_DIR/no_read_file"
      When call is_empty "$TEST_DIR/no_read_file"
      The status should be success
      The stderr should not be present
    End

    It 'returns 1 for an unreadable, non-empty file'
      touch "$TEST_DIR/no_read_file"
      echo "data" >> "$TEST_DIR/no_read_file"
      chmod a-r "$TEST_DIR/no_read_file"
      When call is_empty "$TEST_DIR/no_read_file"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns 2 for an unreadable, empty directory'
      mkdir "$TEST_DIR/no_read_dir"
      chmod a-r "$TEST_DIR/no_read_dir"
      When call is_empty "$TEST_DIR/no_read_dir"
      The status should equal 2
      The stderr should not be present
    End

    It 'returns 2 for an unreadable, non-empty directory'
      mkdir "$TEST_DIR/no_read_dir"
      touch "$TEST_DIR/no_read_dir/file"
      chmod a-r "$TEST_DIR/no_read_dir"
      When call is_empty "$TEST_DIR/no_read_dir"
      The status should equal 2
      The stderr should not be present
      chmod +r "$TEST_DIR/no_read_dir" # make readable again to allow cleanup
    End

    It 'returns success for a non-executable, empty directory'
      mkdir "$TEST_DIR/no_ex_dir"
      chmod -x "$TEST_DIR/no_ex_dir"
      When call is_empty "$TEST_DIR/no_ex_dir"
      The status should be success
      The stderr should not be present
    End

    It 'returns 1 for a non-executable, non-empty directory'
      mkdir "$TEST_DIR/no_ex_dir"
      touch "$TEST_DIR/no_ex_dir/file"
      chmod -x "$TEST_DIR/no_ex_dir"
      When call is_empty "$TEST_DIR/no_ex_dir"
      The status should equal 1
      The stderr should not be present
      chmod +x "$TEST_DIR/no_ex_dir" # allows cleanup
    End

    It 'returns success for an empty file with an unreadable parent directory'
      mkdir "$TEST_DIR/no_read_parent"
      touch "$TEST_DIR/no_read_parent/file"
      chmod a-r "$TEST_DIR/no_read_parent"
      When call is_empty "$TEST_DIR/no_read_parent/file"
      The status should be success
      The stderr should not be present
      chmod +r "$TEST_DIR/no_read_parent" # allows cleanup
    End

    It 'returns 1 for a non-empty file with an unreadable parent directory'
      mkdir "$TEST_DIR/no_read_parent"
      touch "$TEST_DIR/no_read_parent/file"
      echo "data" >> "$TEST_DIR/no_read_parent/file"
      chmod a-r "$TEST_DIR/no_read_parent"
      When call is_empty "$TEST_DIR/no_read_parent/file"
      The status should equal 1
      The stderr should not be present
      chmod +r "$TEST_DIR/no_read_parent" # allows cleanup
    End

    It 'returns success for an empty directory with an unreadable parent directory'
      mkdir "$TEST_DIR/no_read_parent"
      mkdir "$TEST_DIR/no_read_parent/dir"
      chmod a-r "$TEST_DIR/no_read_parent"
      When call is_empty "$TEST_DIR/no_read_parent/dir"
      The status should be success
      The stderr should not be present
      chmod +r "$TEST_DIR/no_read_parent" # allows cleanup
    End

    It 'returns 1 for a non-empty directory with an unreadable parent directory'
      mkdir "$TEST_DIR/no_read_parent"
      mkdir "$TEST_DIR/no_read_parent/dir"
      touch "$TEST_DIR/no_read_parent/dir/file"
      chmod a-r "$TEST_DIR/no_read_parent"
      When call is_empty "$TEST_DIR/no_read_parent/dir"
      The status should equal 1
      The stderr should not be present
      chmod +r "$TEST_DIR/no_read_parent" # allows cleanup
    End

    It 'returns 2 for a file with a non-executable parent directory'
      mkdir "$TEST_DIR/no_read_parent"
      touch "$TEST_DIR/no_read_parent/file"
      chmod -x "$TEST_DIR/no_read_parent"
      When call is_empty "$TEST_DIR/no_read_parent/file"
      The status should equal 2
      The stderr should not be present
      chmod +x "$TEST_DIR/no_read_parent" # allows cleanup
    End

    It 'returns 2 for a directory with an non-executable parent directory'
      mkdir "$TEST_DIR/no_read_parent"
      mkdir "$TEST_DIR/no_read_parent/dir"
      chmod -x "$TEST_DIR/no_read_parent"
      When call is_empty "$TEST_DIR/no_read_parent/dir"
      The status should equal 2
      The stderr should not be present
      chmod +x "$TEST_DIR/no_read_parent" # allows cleanup
    End
  End

  # ======================================
  # Edge Cases: Special File Types
  # ======================================
  Describe 'with special file types'
    It 'returns 2 for a named pipe (FIFO)'
      mkfifo "$TEST_DIR/test_fifo"
      When call is_empty "$TEST_DIR/test_fifo"
      The status should equal 2
      The stderr should not be present
    End

    It 'returns 2 for a block/character device like /dev/null'
      When call is_empty "/dev/null"
      The status should equal 2
      The stderr should not be present
    End
  End

  # ======================================
  # Edge Cases: Boundary / Misc
  # ======================================
  Describe 'boundary and miscellaneous cases'
    It 'returns success for a newly created temp file (via mktemp)'
      tmpfile="$(mktemp "$TEST_DIR/tmp.XXXXXX")"
      When call is_empty "$tmpfile"
      The status should be success
      The stderr should not be present
    End

    It 'returns 1 for a large non-empty file'
      dd if=/dev/urandom of="$TEST_DIR/large_file" bs=1024 count=100 2>/dev/null
      When call is_empty "$TEST_DIR/large_file"
      The status should equal 1
      The stderr should not be present
    End

    It 'returns success for a directory after its only file is removed'
      mkdir "$TEST_DIR/was_full_dir"
      touch "$TEST_DIR/was_full_dir/temp_file"
      rm "$TEST_DIR/was_full_dir/temp_file"
      When call is_empty "$TEST_DIR/was_full_dir"
      The status should be success
      The stderr should not be present
    End

    It 'handles a path with trailing slashes for a directory'
      mkdir "$TEST_DIR/trailing_slash_dir"
      When call is_empty "$TEST_DIR/trailing_slash_dir///"
      The status should be success
      The stderr should not be present
    End

    It 'handles a path with redundant components (..)'
      mkdir "$TEST_DIR/parent_dir"
      mkdir "$TEST_DIR/parent_dir/child_dir"
      touch "$TEST_DIR/empty_file"
      When call is_empty "$TEST_DIR/parent_dir/child_dir/../../empty_file"
      The status should be success
      The stderr should not be present
    End
  End
End
