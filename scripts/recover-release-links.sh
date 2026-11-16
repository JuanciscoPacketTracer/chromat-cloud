#!/usr/bin/env bash
set -Eeuo pipefail

root=/srv/chromat
state=
lock_file=/var/lock/chromat-promotion.lock
while (($#)); do
  case "$1" in
    --root)
      root="${2:-}"
      shift 2
      ;;
    --state)
      state="${2:-}"
      shift 2
      ;;
    --lock-file)
      lock_file="${2:-}"
      shift 2
      ;;
    *)
      printf 'Usage: %s [--root DIRECTORY] [--state FILE] [--lock-file FILE]\n' "${0##*/}" >&2
      exit 2
      ;;
  esac
done

lock_parent="$(realpath -e -- "$(dirname -- "$lock_file")")" || {
  printf 'lock directory does not exist: %s\n' "$(dirname -- "$lock_file")" >&2
  exit 2
}
lock_file="$lock_parent/$(basename -- "$lock_file")"
[[ -d "$lock_parent" && ! -L "$lock_parent" ]] || {
  printf 'lock directory must be a real directory: %s\n' "$lock_parent" >&2
  exit 2
}
[[ "$(stat -c %u -- "$lock_parent")" == 0 ]] || {
  printf 'lock directory must be owned by root: %s\n' "$lock_parent" >&2
  exit 2
}
lock_parent_mode="$(stat -c %a -- "$lock_parent")"
if (( (8#$lock_parent_mode & 0022) != 0 && (8#$lock_parent_mode & 01000) == 0 )); then
  printf 'writable lock directory must have the sticky bit: %s\n' "$lock_parent" >&2
  exit 2
fi
if [[ -L "$lock_file" ]]; then
  printf 'lock file must not be a symbolic link: %s\n' "$lock_file" >&2
  exit 2
fi
if [[ ! -e "$lock_file" ]]; then
  (
    umask 077
    set -C
    : >"$lock_file"
  ) 2>/dev/null || true
fi
[[ -f "$lock_file" && ! -L "$lock_file" ]] || {
  printf 'lock file must be a regular non-symlink file: %s\n' "$lock_file" >&2
  exit 2
}
[[ "$(stat -c %u -- "$lock_file")" == 0 ]] || {
  printf 'lock file must be owned by root: %s\n' "$lock_file" >&2
  exit 2
}
[[ "$(stat -c %a -- "$lock_file")" == 600 ]] || {
  printf 'lock file must have mode 0600: %s\n' "$lock_file" >&2
  exit 2
}
if [[ "${CHROMAT_PROMOTION_LOCK_HELD:-}" == 1 ]]; then
  [[ -e /proc/self/fd/9 ]] &&
    [[ "$(stat -Lc '%d:%i' -- /proc/self/fd/9)" == "$(stat -Lc '%d:%i' -- "$lock_file")" ]] || {
    printf 'inherited promotion lock descriptor is invalid\n' >&2
    exit 2
  }
else
  exec 9<>"$lock_file"
fi
flock -n 9 || {
  printf 'another promotion or recovery is active\n' >&2
  exit 1
}

root="$(realpath -e -- "$root")"
[[ -d "$root/releases" ]] || {
  printf 'release directory does not exist: %s/releases\n' "$root" >&2
  exit 2
}
state="${state:-$root/.promotion-link-state}"
state_directory="$(realpath -e -- "$(dirname -- "$state")")"
state="$state_directory/$(basename -- "$state")"
[[ "$state_directory" == "$root" ]] || {
  printf 'state file must be directly inside release root: %s\n' "$state" >&2
  exit 2
}
[[ -f "$state" && ! -L "$state" ]] || {
  printf 'state file must be a regular non-symlink file: %s\n' "$state" >&2
  exit 2
}
[[ "$(stat -c %u -- "$state")" == 0 ]] || {
  printf 'state file must be owned by root: %s\n' "$state" >&2
  exit 2
}
[[ "$(stat -c %a -- "$state")" == 600 ]] || {
  printf 'state file must have mode 0600: %s\n' "$state" >&2
  exit 2
}

declare -A values=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" == *=* ]] || {
    printf 'invalid release link state line\n' >&2
    exit 2
  }
  key="${line%%=*}"
  value="${line#*=}"
  case "$key" in
    active_exists|active_target|previous_exists|previous_target)
      [[ -z "${values[$key]+x}" ]] || {
        printf 'duplicate release link state key: %s\n' "$key" >&2
        exit 2
      }
      values["$key"]="$value"
      ;;
    *)
      printf 'unknown release link state key: %s\n' "$key" >&2
      exit 2
      ;;
  esac
done <"$state"

for key in active_exists active_target previous_exists previous_target; do
  [[ -n "${values[$key]+x}" ]] || {
    printf 'missing release link state key: %s\n' "$key" >&2
    exit 2
  }
done
for link in active previous; do
  exists_key="${link}_exists"
  target_key="${link}_target"
  case "${values[$exists_key]}" in
    0)
      [[ -z "${values[$target_key]}" ]] || {
        printf '%s target must be empty when link is absent\n' "$link" >&2
        exit 2
      }
      ;;
    1)
      target="$(realpath -e -- "${values[$target_key]}")" || {
        printf '%s target is not a release directory: %s\n' \
          "$link" "${values[$target_key]}" >&2
        exit 2
      }
      [[ -d "$target" && "$target" == "$root/releases/"* ]] || {
        printf '%s target is outside the release directory: %s\n' \
          "$link" "${values[$target_key]}" >&2
        exit 2
      }
      values["$target_key"]="$target"
      ;;
    *)
      printf '%s_exists must be 0 or 1\n' "$link" >&2
      exit 2
      ;;
  esac
done

for link in active previous; do
  destination="$root/$link"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -L "$destination" ]] || {
      printf 'refusing to replace non-symlink release path: %s\n' "$destination" >&2
      exit 2
    }
  fi
done

for temporary_link in "$root/.active.next" "$root/.previous.next"; do
  if [[ -e "$temporary_link" || -L "$temporary_link" ]]; then
    [[ -L "$temporary_link" ]] || {
      printf 'refusing to remove non-symlink temporary path: %s\n' "$temporary_link" >&2
      exit 2
    }
    rm -f -- "$temporary_link"
  fi
done

restore_link() {
  local name="$1"
  local exists="$2"
  local target="$3"
  local destination="$root/$name"
  local temporary="$root/.${name}.next"

  if [[ "$exists" == 0 ]]; then
    rm -f -- "$destination"
    return
  fi
  ln -s -- "$target" "$temporary"
  mv -Tf -- "$temporary" "$destination"
}

restore_link previous "${values[previous_exists]}" "${values[previous_target]}"
restore_link active "${values[active_exists]}" "${values[active_target]}"

for link in active previous; do
  exists_key="${link}_exists"
  target_key="${link}_target"
  path="$root/$link"
  if [[ "${values[$exists_key]}" == 0 ]]; then
    [[ ! -e "$path" && ! -L "$path" ]] || {
      printf '%s was not removed during recovery\n' "$link" >&2
      exit 1
    }
  elif [[ "$(readlink -f -- "$path")" != "${values[$target_key]}" ]]; then
    printf '%s does not match the persisted recovery target\n' "$link" >&2
    exit 1
  fi
done

rm -f -- "$state"
printf 'Release links recovered under %s\n' "$root"
