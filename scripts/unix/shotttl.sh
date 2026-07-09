#!/usr/bin/env bash

set -u

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
    printf 'ShotTTL: HOME is not set to an existing directory; refusing to run.\n' >&2
    exit 2
fi
: "${PWD:=$(pwd)}"

TARGET_DIR=""
RETENTION_MINUTES=1440
DELETE_MODE="Trash"
DRY_RUN=0
INCLUDE_SUBFOLDERS=0
QUIET=0
CREATE_TARGET_IF_MISSING=0
LOG_DIR="${HOME}/.shotttl/logs"
TRASH_BACKEND_NOT_FOUND=127

show_help() {
    cat <<'HELP'
ShotTTL - Give your screenshots a TTL.

Usage:
  ./shotttl.sh [--target PATH] [--keep N(m|h|d)] [--trash|--delete] [--dry-run]

Options:
  --target PATH              Screenshot folder to clean. Auto-detected when omitted.
  --keep N(m|h|d)            Keep files modified within this period (e.g. 30m, 1h, 24h, 7d).
                             Any positive N with one of m/h/d is accepted; units are case-insensitive.
  --retention-minutes MIN    Keep files modified within this many minutes. Default: 1440.
  --trash                    Move old images to trash. Default.
  --delete                   Permanently delete old images.
  --dry-run                  Show what would be removed without changing files.
  --include-subfolders       Include files in child folders. Default: off.
  --quiet                    Reduce console output. Logs are still written.
  --create-target-if-missing Create the target folder when it does not exist.
  --help                     Show this help.

Examples:
  ./shotttl.sh --target "$HOME/Pictures/Screenshots" --keep 24h --dry-run
  ./shotttl.sh --target /tmp/shotttl-test --keep 24h --delete
HELP
}

say() {
    if [ "$QUIET" -ne 1 ]; then
        printf '%s\n' "$*"
    fi
}

log() {
    local level message safe_message log_file
    level="$1"
    message="$2"
    # Strip C0 control bytes and DEL so a malicious filename can't fake a log row.
    safe_message=$(printf '%s' "$message" | tr -d '\000-\037\177')
    # Resolve log path per call so a day-crossing long run lands on the new file.
    log_file="${LOG_DIR}/shotttl_$(date +%Y%m%d).log"

    if mkdir -p "$LOG_DIR" 2>/dev/null; then
        # Prefer owner-only logs on shared hosts (best-effort; ignore failure).
        chmod 700 "$LOG_DIR" 2>/dev/null || true
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$safe_message" >> "$log_file" 2>/dev/null || true
        chmod 600 "$log_file" 2>/dev/null || true
    fi
}

format_bytes() {
    local bytes
    bytes="$1"
    awk -v bytes="$bytes" 'BEGIN {
        if (bytes >= 1073741824) {
            printf "%.1f GB", bytes / 1073741824
        } else if (bytes >= 1048576) {
            printf "%.1f MB", bytes / 1048576
        } else if (bytes >= 1024) {
            printf "%.1f KB", bytes / 1024
        } else {
            printf "%d B", bytes
        }
    }'
}

parse_keep_to_minutes() {
    local value amount unit minutes
    value="$1"

    if [[ ! "$value" =~ ^([0-9]+)([mhdMHD])$ ]]; then
        printf 'Invalid --keep value: %s\n' "$value" >&2
        return 1
    fi

    amount="${BASH_REMATCH[1]}"
    unit=$(printf '%s' "${BASH_REMATCH[2]}" | tr 'MHD' 'mhd')

    case "$unit" in
        m) minutes="$amount" ;;
        h) minutes=$((amount * 60)) ;;
        d) minutes=$((amount * 1440)) ;;
        *) return 1 ;;
    esac

    if [ "$minutes" -lt 1 ] || [ "$minutes" -gt 525600 ]; then
        printf 'Retention must be between 1 and 525600 minutes.\n' >&2
        return 1
    fi

    printf '%s\n' "$minutes"
}

is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -ge 1 ] && [ "$1" -le 525600 ] ;;
    esac
}

expand_path() {
    local path
    path="$1"

    case "$path" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s/%s\n' "$HOME" "${path#~/}" ;;
        /*) printf '%s\n' "$path" ;;
        *) printf '%s/%s\n' "$PWD" "$path" ;;
    esac
}

strip_trailing_slashes() {
    local path
    path="$1"

    if [ "$path" = "/" ]; then
        printf '/\n'
        return
    fi

    while [ "${path%/}" != "$path" ]; do
        path="${path%/}"
    done

    printf '%s\n' "$path"
}

normalize_path() {
    local expanded normalized dir base resolved
    expanded="$(expand_path "$1")"

    if [ -d "$expanded" ]; then
        resolved="$(cd "$expanded" 2>/dev/null && pwd -P)"
        if [ -n "$resolved" ]; then
            normalized="$resolved"
        else
            normalized="$expanded"
        fi
    else
        dir="$(dirname "$expanded")"
        base="$(basename "$expanded")"
        if [ -d "$dir" ]; then
            resolved="$(cd "$dir" 2>/dev/null && pwd -P)"
            if [ -n "$resolved" ]; then
                normalized="$resolved/$base"
            else
                normalized="$expanded"
            fi
        else
            normalized="$expanded"
        fi
    fi

    strip_trailing_slashes "$normalized"
}

# Return 0 if any path component (including intermediate dirs) is a symlink.
# Used to block allowlist/denylist escapes via e.g. ~/Pictures -> /evil.
path_has_symlink_component() {
    local path cur rest part
    path="$(strip_trailing_slashes "$1")"
    case "$path" in
        /*) rest="${path#/}" ;;
        *) return 1 ;;
    esac

    cur=""
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        if [ "$part" = "$rest" ]; then
            rest=""
        else
            rest="${rest#*/}"
        fi
        [ -z "$part" ] && continue
        cur="$cur/$part"
        if [ -L "$cur" ]; then
            return 0
        fi
    done
    return 1
}

is_unsafe_target() {
    local raw target home_path expanded home_expanded
    raw="$1"
    expanded="$(expand_path "$raw")"
    expanded="$(strip_trailing_slashes "$expanded")"
    home_expanded="$(strip_trailing_slashes "$(expand_path "$HOME")")"
    target="$(normalize_path "$raw")"
    home_path="$(normalize_path "$HOME")"

    case "$target" in
        ""|"/") return 0 ;;
    esac

    # Refuse if the entry point OR any intermediate component is a symlink.
    # Intermediate links (e.g. ~/Pictures -> /tmp/attacker) otherwise resolve
    # outside both the allowlist and the home danger prefixes and get allowed.
    if path_has_symlink_component "$expanded"; then
        return 0
    fi

    # Lexical path under $HOME but resolved path escaped $HOME → refuse.
    case "$expanded" in
        "$home_expanded"|"$home_expanded"/*)
            case "$target" in
                "$home_path"|"$home_path"/*) ;;
                *) return 0 ;;
            esac
            ;;
    esac

    # Allowlist of dedicated screenshot folders (compared post-resolution).
    # Paths are also normalized so minor . / .. forms still match.
    case "$target" in
        "$home_path/Pictures/Screenshots"|"$home_path/.claude/screenshots"|"$home_path/Desktop/Screenshots")
            return 1
            ;;
    esac

    # Danger list: refuse exact match AND any subfolder (path-prefix). The
    # allowlist above already returned 1 for the dedicated screenshot dirs, so
    # remaining subfolders of Desktop/Downloads/Documents/Pictures (e.g.
    # ~/Documents/Reports) are correctly refused here.
    case "$target" in
        "$home_path"|"$home_path/Desktop"|"$home_path/Downloads"|"$home_path/Documents"|"$home_path/Pictures") return 0 ;;
        "$home_path/Desktop"/*|"$home_path/Downloads"/*|"$home_path/Documents"/*|"$home_path/Pictures"/*) return 0 ;;
    esac

    return 1
}

detect_default_target() {
    local os_name configured candidates candidate
    os_name="$(uname -s 2>/dev/null || printf 'Unknown')"

    if [ "$os_name" = "Darwin" ] && command -v defaults >/dev/null 2>&1; then
        configured="$(defaults read com.apple.screencapture location 2>/dev/null || true)"
        if [ -n "$configured" ] && [ -d "$(expand_path "$configured")" ] && ! is_unsafe_target "$configured"; then
            normalize_path "$configured"
            return
        fi
    fi

    candidates="$HOME/Pictures/Screenshots
$HOME/.claude/screenshots
$HOME/Desktop/Screenshots"

    while IFS= read -r candidate; do
        if [ -n "$candidate" ] && [ -d "$candidate" ] && ! is_unsafe_target "$candidate"; then
            normalize_path "$candidate"
            return
        fi
    done <<EOF
$candidates
EOF

    printf '%s\n' "$HOME/Pictures/Screenshots"
}

is_image_file() {
    local file lower
    file="$1"
    lower="$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')"

    case "$lower" in
        *.png|*.jpg|*.jpeg|*.webp|*.bmp|*.gif) return 0 ;;
        *) return 1 ;;
    esac
}

file_mtime_epoch() {
    local file
    file="$1"

    stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null
}

file_size_bytes() {
    local file
    file="$1"

    stat -c '%s' "$file" 2>/dev/null || stat -f '%z' "$file" 2>/dev/null || wc -c < "$file"
}

unique_trash_path() {
    local source trash_dir base destination timestamp name ext counter
    source="$1"
    trash_dir="$2"
    base="$(basename "$source")"
    destination="$trash_dir/$base"

    if [ ! -e "$destination" ]; then
        printf '%s\n' "$destination"
        return
    fi

    timestamp="$(date +%Y%m%d_%H%M%S)"

    case "$base" in
        *.*)
            name="${base%.*}"
            ext=".${base##*.}"
            ;;
        *)
            name="$base"
            ext=""
            ;;
    esac

    counter=1
    while :; do
        destination="$trash_dir/${name}_${timestamp}_${counter}${ext}"
        if [ ! -e "$destination" ]; then
            printf '%s\n' "$destination"
            return
        fi
        counter=$((counter + 1))
    done
}

move_to_trash() {
    local file os_name trash_dir destination status
    file="$1"
    os_name="$(uname -s 2>/dev/null || printf 'Unknown')"

    if [ "$os_name" = "Darwin" ]; then
        trash_dir="$HOME/.Trash"
        mkdir -p "$trash_dir" || return 1
        destination="$(unique_trash_path "$file" "$trash_dir")"
        # -n refuses to clobber if a racy concurrent writer created the
        # destination after unique_trash_path's check; retry once with a
        # freshly chosen name to absorb the TOCTOU window.
        # BSD mv -n can return 0 as a silent no-op when the destination
        # already exists — always verify the source disappeared.
        if ! mv -n "$file" "$destination" 2>/dev/null || [ -e "$file" ]; then
            destination="$(unique_trash_path "$file" "$trash_dir")"
            mv -n "$file" "$destination" || return 1
            if [ -e "$file" ]; then
                return 1
            fi
        fi
        return 0
    fi

    # Try each available backend in turn. If one fails at runtime
    # (e.g. gio across filesystems failing to write .trashinfo), fall
    # through to the next. Never fall back to rm. Re-check existence
    # before each attempt so a partial move by a prior backend does not
    # produce a spurious failure.
    # stderr goes to the daily log (resolved per call) so cron MAILTO
    # is not flooded; diagnostic detail is preserved.
    log_file="${LOG_DIR}/shotttl_$(date +%Y%m%d).log"
    mkdir -p "$LOG_DIR" 2>/dev/null || true

    if command -v gio >/dev/null 2>&1; then
        [ -e "$file" ] || return 0
        gio trash "$file" 2>>"$log_file" && return 0
    fi

    if command -v trash-put >/dev/null 2>&1; then
        [ -e "$file" ] || return 0
        trash-put "$file" 2>>"$log_file" && return 0
    fi

    if command -v kioclient5 >/dev/null 2>&1; then
        [ -e "$file" ] || return 0
        kioclient5 move "$file" trash:/ 2>>"$log_file" && return 0
    fi

    if command -v kioclient >/dev/null 2>&1; then
        [ -e "$file" ] || return 0
        kioclient move "$file" trash:/ 2>>"$log_file" && return 0
    fi

    return "$TRASH_BACKEND_NOT_FOUND"
}

cleanup() {
    local target cutoff candidates deleted failed freed would_free find_command file relative base mtime size status reason
    target="$(normalize_path "$TARGET_DIR")"
    cutoff=$(( $(date +%s) - RETENTION_MINUTES * 60 ))
    candidates=0
    deleted=0
    failed=0
    freed=0
    would_free=0

    log "INFO" "Run started. Target=${target}; RetentionMinutes=${RETENTION_MINUTES}; DeleteMode=${DELETE_MODE}; DryRun=${DRY_RUN}; IncludeSubfolders=${INCLUDE_SUBFOLDERS}"

    if [ "$INCLUDE_SUBFOLDERS" -eq 1 ]; then
        find_command=(find "$target" -type f -print0)
    else
        find_command=(find "$target" -type d ! -path "$target" -prune -o -type f -print0)
    fi

    while IFS= read -r -d '' file; do
        relative="${file#$target/}"
        base="$(basename "$file")"
        case "$relative" in
            .*|*/.*) continue ;;
        esac
        case "$base" in
            .*) continue ;;
        esac

        if ! is_image_file "$file"; then
            continue
        fi

        mtime="$(file_mtime_epoch "$file" || true)"
        if [ -z "$mtime" ] || [ "$mtime" -ge "$cutoff" ]; then
            continue
        fi

        size="$(file_size_bytes "$file" | tr -d '[:space:]')"
        case "$size" in
            ''|*[!0-9]*) size=0 ;;
        esac

        candidates=$((candidates + 1))

        if [ "$DRY_RUN" -eq 1 ]; then
            would_free=$((would_free + size))
            log "INFO" "DRY-RUN candidate: ${file} ($(format_bytes "$size"))"
            say "Would remove: $file"
            continue
        fi

        # TOCTOU: re-validate immediately before destructive action so a
        # path swapped to a symlink after find cannot redirect the delete.
        if [ -L "$file" ] || [ ! -f "$file" ]; then
            failed=$((failed + 1))
            log "ERROR" "Failed to remove ${file}: path is no longer a regular non-symlink file"
            say "Failed: $file (path is no longer a regular non-symlink file)"
            continue
        fi

        if [ "$DELETE_MODE" = "Trash" ]; then
            if move_to_trash "$file"; then
                deleted=$((deleted + 1))
                freed=$((freed + size))
                log "INFO" "Removed via Trash: ${file} ($(format_bytes "$size"))"
            else
                status=$?
                failed=$((failed + 1))
                if [ "$status" -eq "$TRASH_BACKEND_NOT_FOUND" ]; then
                    reason="No supported trash command found; refusing to fall back to rm"
                else
                    reason="Trash command failed with exit code ${status}"
                fi
                log "ERROR" "Failed to trash ${file}: ${reason}"
                say "Failed: $file ($reason)"
            fi
        else
            if rm -f -- "$file"; then
                deleted=$((deleted + 1))
                freed=$((freed + size))
                log "INFO" "Removed via Delete: ${file} ($(format_bytes "$size"))"
            else
                failed=$((failed + 1))
                log "ERROR" "Failed to delete ${file}"
                say "Failed: $file"
            fi
        fi
    done < <("${find_command[@]}")

    if [ "$DRY_RUN" -eq 1 ]; then
        log "INFO" "Dry-run completed. Candidates=${candidates}; WouldFree=$(format_bytes "$would_free")"
        say "ShotTTL dry-run completed."
        say "Target: $target"
        say "Candidates: $candidates"
        say "Would free: $(format_bytes "$would_free")"
        say "No files were deleted."
        say "Mode: $DELETE_MODE"
    else
        log "INFO" "Cleanup completed. Candidates=${candidates}; Deleted=${deleted}; Failed=${failed}; Freed=$(format_bytes "$freed"); Mode=${DELETE_MODE}"
        say "ShotTTL cleanup completed."
        say "Target: $target"
        say "Candidates: $candidates"
        say "Deleted: $deleted"
        say "Failed: $failed"
        say "Freed: $(format_bytes "$freed")"
        say "Mode: $DELETE_MODE"
    fi

    if [ "$failed" -gt 0 ]; then
        return 1
    fi

    return 0
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            [ "$#" -ge 2 ] || { printf 'Missing value for --target\n' >&2; exit 1; }
            TARGET_DIR="$2"
            shift 2
            ;;
        --target=*)
            TARGET_DIR="${1#--target=}"
            shift
            ;;
        --keep)
            [ "$#" -ge 2 ] || { printf 'Missing value for --keep\n' >&2; exit 1; }
            RETENTION_MINUTES="$(parse_keep_to_minutes "$2")" || exit 1
            shift 2
            ;;
        --keep=*)
            RETENTION_MINUTES="$(parse_keep_to_minutes "${1#--keep=}")" || exit 1
            shift
            ;;
        --retention-minutes)
            [ "$#" -ge 2 ] || { printf 'Missing value for --retention-minutes\n' >&2; exit 1; }
            is_positive_integer "$2" || { printf 'Retention must be between 1 and 525600 minutes.\n' >&2; exit 1; }
            RETENTION_MINUTES="$2"
            shift 2
            ;;
        --retention-minutes=*)
            _retention_value="${1#--retention-minutes=}"
            is_positive_integer "$_retention_value" || { printf 'Retention must be between 1 and 525600 minutes.\n' >&2; exit 1; }
            RETENTION_MINUTES="$_retention_value"
            unset _retention_value
            shift
            ;;
        --trash)
            DELETE_MODE="Trash"
            shift
            ;;
        --delete)
            DELETE_MODE="Delete"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --include-subfolders)
            INCLUDE_SUBFOLDERS=1
            shift
            ;;
        --quiet)
            QUIET=1
            shift
            ;;
        --create-target-if-missing)
            CREATE_TARGET_IF_MISSING=1
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR="$(detect_default_target)"
fi

TARGET_DIR="$(normalize_path "$TARGET_DIR")"

if is_unsafe_target "$TARGET_DIR"; then
    log "ERROR" "Refusing unsafe target directory: ${TARGET_DIR}"
    printf 'ShotTTL refuses to clean this broad or unsafe target: %s\n' "$TARGET_DIR" >&2
    exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
    if [ "$CREATE_TARGET_IF_MISSING" -eq 1 ]; then
        if mkdir -p "$TARGET_DIR" 2>/dev/null; then
            log "INFO" "Created missing target directory: ${TARGET_DIR}"
        else
            log "ERROR" "Failed to create target directory: ${TARGET_DIR}"
            printf 'Failed to create target directory: %s\n' "$TARGET_DIR" >&2
            exit 1
        fi
    else
        log "ERROR" "Target directory does not exist: ${TARGET_DIR}"
        printf 'Target directory does not exist: %s. Use --create-target-if-missing to create it.\n' "$TARGET_DIR" >&2
        exit 1
    fi
fi

cleanup
