#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '%s\n' "::error::$*" >&2
  exit 1
}

validate_single_line() {
  local name="$1"
  local value="$2"

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    fail "$name must not contain a newline."
  fi
}

resolve_workspace_directory() {
  local name="$1"
  local value="$2"
  local component
  local directory="$workspace_path"
  local path_components=()
  local IFS='/'

  [[ "$value" != /* ]] ||
    fail "$name must be relative to GITHUB_WORKSPACE."

  read -r -a path_components <<< "$value"

  for component in "${path_components[@]}"; do
    case "$component" in
      "" | .)
        continue
        ;;
      ..)
        fail "$name must not leave GITHUB_WORKSPACE."
        ;;
      .git)
        fail "$name must not include a Git administrative directory."
        ;;
    esac

    directory="$directory/$component"
    [[ ! -L "$directory" ]] ||
      fail "$name must not contain symbolic links."
  done

  [[ -d "$directory" ]] ||
    fail "$name does not exist or is not a directory: $value"

  printf '%s\n' "$directory"
}

ensure_no_symlinks() {
  local name="$1"
  local directory="$2"
  local first_symlink

  if ! first_symlink="$(find "$directory" -type l -print -quit)"; then
    fail "Could not inspect $name for symbolic links."
  fi

  [[ -z "$first_symlink" ]] ||
    fail "$name must not contain symbolic links."
}

create_workspace_output_parent() {
  local value="$1"
  local component
  local directory="$workspace_path"
  local path_components=()
  local IFS='/'

  read -r -a path_components <<< "$value"

  for component in "${path_components[@]}"; do
    case "$component" in
      "" | .)
        continue
        ;;
      ..)
        fail "output_path must not leave GITHUB_WORKSPACE."
        ;;
      .git)
        fail "output_path must not include a Git administrative directory."
        ;;
    esac

    directory="$directory/$component"

    if [[ -L "$directory" ]]; then
      fail "output_path must not contain symbolic links."
    fi

    if [[ -e "$directory" ]]; then
      [[ -d "$directory" ]] ||
        fail "output_path parent is not a directory: $value"
    else
      mkdir "$directory"
    fi
  done

  printf '%s\n' "$directory"
}

copy_directory_contents() {
  local source="$1"
  local destination="$2"

  mkdir -p "$destination"
  cp -a "$source"/. "$destination"/
}

copy_source_contents() {
  local source="$1"
  local destination="$2"
  local item
  local name

  mkdir -p "$destination"

  for item in "$source"/.[!.]* "$source"/..?* "$source"/*; do
    [[ -e "$item" || -L "$item" ]] || continue
    name="${item##*/}"

    case "$name" in
      .git | .github | .mypy_cache | .pytest_cache | .venv | __pycache__ | node_modules | venv)
        continue
        ;;
    esac

    cp -a "$item" "$destination"/
  done
}

matches_exclusion() {
  local entry_path="$1"
  local pattern

  for pattern in "${exclude_patterns[@]}"; do
    # Exclusion input deliberately uses Bash glob patterns.
    # shellcheck disable=SC2053
    [[ "$entry_path" == $pattern ]] && return 0
  done

  return 1
}

remove_excluded_entries() {
  local directory="$1"
  local entry
  local entry_path

  while IFS= read -r -d '' entry; do
    entry_path="${entry#"$directory"/}"
    if matches_exclusion "$entry_path"; then
      rm -rf -- "$entry"
    fi
  done < <(find "$directory" -depth -mindepth 1 -print0)
}

readonly workspace="${GITHUB_WORKSPACE:-$PWD}"
readonly mode="${INPUT_MODE:-zip}"
readonly runtime="${INPUT_RUNTIME:-}"
readonly source_dir_input="${INPUT_SOURCE_DIR:-}"
readonly dependencies_dir_input="${INPUT_DEPENDENCIES_DIR:-}"
readonly output_path_input="${INPUT_OUTPUT_PATH:-lambda-package.zip}"
readonly exclude_input="${INPUT_EXCLUDE:-}"

validate_single_line "mode" "$mode"
validate_single_line "runtime" "$runtime"
validate_single_line "source_dir" "$source_dir_input"
validate_single_line "dependencies_dir" "$dependencies_dir_input"
validate_single_line "output_path" "$output_path_input"

case "$mode" in
  zip | layer)
    ;;
  *)
    fail "mode must be either 'zip' or 'layer', got '$mode'."
    ;;
esac

case "$runtime" in
  python | node)
    ;;
  *)
    fail "runtime must be either 'python' or 'node', got '$runtime'."
    ;;
esac

[[ -n "$output_path_input" ]] || fail "output_path is required."
[[ "$output_path_input" != /* ]] || fail "output_path must be relative to the workspace."
[[ "$output_path_input" == *.zip ]] || fail "output_path must end in .zip."

workspace_path="$(cd "$workspace" && pwd -P)" ||
  fail "GITHUB_WORKSPACE does not exist: $workspace"
readonly workspace_path
output_parent_input="$(dirname "$output_path_input")"
readonly output_parent_input
output_name="$(basename "$output_path_input")"
readonly output_name
output_parent="$(create_workspace_output_parent "$output_parent_input")"
readonly output_parent
readonly archive_path="$output_parent/$output_name"

case "$archive_path" in
  "$workspace_path"/*)
    ;;
  *)
    fail "output_path must resolve within the workspace."
    ;;
esac

[[ ! -d "$archive_path" ]] || fail "output_path points to a directory: $output_path_input"
rm -f -- "$archive_path"

source_dir=""
if [[ -n "$source_dir_input" ]]; then
  source_dir="$(resolve_workspace_directory "source_dir" "$source_dir_input")"
  ensure_no_symlinks "source_dir" "$source_dir"
fi

dependencies_dir=""
if [[ -n "$dependencies_dir_input" ]]; then
  dependencies_dir="$(resolve_workspace_directory \
    "dependencies_dir" "$dependencies_dir_input")"
  ensure_no_symlinks "dependencies_dir" "$dependencies_dir"
fi

if [[ "$runtime" == "node" && -n "$dependencies_dir" ]]; then
  [[ "$(basename "$dependencies_dir")" == "node_modules" ]] ||
    fail "Node.js dependencies_dir must name a node_modules directory."
fi

case "$mode:$runtime" in
  zip:*)
    [[ -n "$source_dir" ]] || fail "source_dir is required for zip mode."
    ;;
  layer:python)
    [[ -n "$source_dir" || -n "$dependencies_dir" ]] ||
      fail "Python layer mode requires source_dir, dependencies_dir, or both."
    ;;
  layer:node)
    [[ -z "$source_dir" ]] ||
      fail "Node.js layer mode does not accept source_dir; install shared code into node_modules."
    [[ -n "$dependencies_dir" ]] ||
      fail "Node.js layer mode requires dependencies_dir."
    ;;
esac

stage_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/lambda-package.XXXXXX")"
trap 'rm -rf -- "$stage_dir"' EXIT

case "$mode:$runtime" in
  zip:python)
    copy_source_contents "$source_dir" "$stage_dir"
    if [[ -n "$dependencies_dir" ]]; then
      copy_directory_contents "$dependencies_dir" "$stage_dir"
    fi
    ;;
  zip:node)
    copy_source_contents "$source_dir" "$stage_dir"
    if [[ -n "$dependencies_dir" ]]; then
      copy_directory_contents "$dependencies_dir" "$stage_dir/node_modules"
    fi
    ;;
  layer:python)
    layer_python_dir="$stage_dir/python"
    if [[ -n "$source_dir" ]]; then
      copy_source_contents "$source_dir" "$layer_python_dir"
    fi
    if [[ -n "$dependencies_dir" ]]; then
      copy_directory_contents "$dependencies_dir" "$layer_python_dir"
    fi
    ;;
  layer:node)
    mkdir -p "$stage_dir/nodejs"
    cp -a "$dependencies_dir" "$stage_dir/nodejs/node_modules"
    ;;
esac

exclude_patterns=(
  ".env"
  ".env.*"
  ".git"
  ".git/*"
  ".github"
  ".github/*"
  ".venv"
  ".venv/*"
  "__pycache__"
  "__pycache__/*"
  "venv"
  "venv/*"
  "*/.env"
  "*/.env.*"
  "*/.git"
  "*/.git/*"
  "*/.github"
  "*/.github/*"
  "*/.venv"
  "*/.venv/*"
  "*/__pycache__"
  "*/__pycache__/*"
  "*/venv"
  "*/venv/*"
  "*.pyc"
)

while IFS= read -r pattern || [[ -n "$pattern" ]]; do
  [[ -n "$pattern" ]] || continue
  [[ "$pattern" != -* && "$pattern" != @* ]] ||
    fail "exclude patterns must not begin with - or @."
  [[ "$pattern" != *$'\r'* ]] ||
    fail "exclude patterns must not contain carriage returns."
  exclude_patterns+=("$pattern")
done <<< "$exclude_input"

remove_excluded_entries "$stage_dir"
ensure_no_symlinks "staged content" "$stage_dir"

if ! find "$stage_dir" -type f -print -quit | grep -q .; then
  fail "No files were staged for packaging."
fi

(
  cd "$stage_dir"
  zip -q -r "$archive_path" .
)

[[ -s "$archive_path" ]] || fail "Archive was not created: $output_path_input"
unzip -tqq "$archive_path" > /dev/null || fail "Archive validation failed: $output_path_input"

case "$mode:$runtime" in
  layer:python)
    unzip -Z1 "$archive_path" | grep -Eq '^(\./)?python/' ||
      fail "Python layer archive is missing python/."
    ;;
  layer:node)
    unzip -Z1 "$archive_path" | grep -Eq '^(\./)?nodejs/node_modules/' ||
      fail "Node.js layer archive is missing nodejs/node_modules/."
    ;;
esac

archive_sha256="$(sha256sum "$archive_path" | awk '{print $1}')"

{
  printf 'zip_path=%s\n' "$archive_path"
  printf 'archive_sha256=%s\n' "$archive_sha256"
} >> "$GITHUB_OUTPUT"
