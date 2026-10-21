#!/bin/bash

# A successful tail must not hide log/sudo failures from calling scripts.
set -o pipefail

# Default values
LINES=50
TIME="5m"
LEVEL="info"
CATEGORY=""
SEARCH=""
OUTPUT=""
DEBUG=false
FOLLOW=false
ERRORS_ONLY=false
NO_TAIL=false
JSON=false
SUBSYSTEM=""
PRIVATE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--lines|-l|--last|-c|--category|-s|--search|-o|--output|--subsystem)
            if [[ $# -lt 2 ]]; then
                printf '%s requires a value\n' "$1" >&2
                exit 2
            fi
            ;;
    esac
    case $1 in
        -n|--lines)
            LINES="$2"
            shift 2
            ;;
        -l|--last)
            TIME="$2"
            shift 2
            ;;
        -c|--category)
            CATEGORY="$2"
            shift 2
            ;;
        -s|--search)
            SEARCH="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT="$2"
            shift 2
            ;;
        -d|--debug)
            DEBUG=true
            LEVEL="debug"
            shift
            ;;
        -f|--follow)
            FOLLOW=true
            shift
            ;;
        -e|--errors)
            ERRORS_ONLY=true
            LEVEL="error"
            shift
            ;;
        -p|--private)
            PRIVATE=true
            shift
            ;;
        --all)
            NO_TAIL=true
            shift
            ;;
        --json)
            JSON=true
            shift
            ;;
        --subsystem)
            SUBSYSTEM="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: pblog.sh [options]"
            echo ""
            echo "Options:"
            echo "  -n, --lines NUM      Text query lines to show (default: 50; JSON/follow are complete)"
            echo "  -l, --last TIME      Time range to search (default: 5m)"
            echo "  -c, --category CAT   Filter by category"
            echo "  -s, --search TEXT    Search for specific text"
            echo "  -o, --output FILE    Output to file"
            echo "  -d, --debug          Show debug level logs"
            echo "  -f, --follow         Stream logs continuously"
            echo "  -e, --errors         Show only errors"
            echo "  -p, --private        Show private data (requires passwordless sudo)"
            echo "  --all                Show all logs without tail limit"
            echo "  --json               Output in JSON format"
            echo "  --subsystem NAME     Filter by subsystem (default: all Wink subsystems)"
            echo "  -h, --help           Show this help"
            echo ""
            echo "Wink subsystems:"
            echo "  boo.wink.core       - Core services"
            echo "  boo.wink.cli        - CLI tool"
            echo "  boo.wink.inspector  - Inspector app"
            echo "  boo.wink.playground - Playground app"
            echo "  boo.wink.app        - Mac app"
            echo "  boo.wink            - Mac app components"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# JSON records span physical lines, and a live stream has no EOF for tail to flush.
# Apply the historical line limit only to completed text queries.
if [[ "$JSON" == true || "$FOLLOW" == true ]]; then
    NO_TAIL=true
fi

# Keep the escaped literal in-shell: command substitution trims trailing newlines.
predicate_literal() {
    PREDICATE_LITERAL="${1//\\/\\\\}"
    PREDICATE_LITERAL="${PREDICATE_LITERAL//\"/\\\"}"
}

# Build predicate - either specific subsystem or all Wink subsystems
if [[ -n "$SUBSYSTEM" ]]; then
    predicate_literal "$SUBSYSTEM"
    PREDICATE="subsystem == \"$PREDICATE_LITERAL\""
else
    # Match all Wink-related subsystems
    PREDICATE="(subsystem == \"boo.wink.core\" OR subsystem == \"boo.wink.inspector\" OR subsystem == \"boo.wink.playground\" OR subsystem == \"boo.wink.app\" OR subsystem == \"boo.wink\" OR subsystem == \"boo.wink.axorcist\" OR subsystem == \"boo.wink.cli\")"
fi

if [[ -n "$CATEGORY" ]]; then
    predicate_literal "$CATEGORY"
    PREDICATE="$PREDICATE AND category == \"$PREDICATE_LITERAL\""
fi

if [[ -n "$SEARCH" ]]; then
    predicate_literal "$SEARCH"
    PREDICATE="$PREDICATE AND eventMessage CONTAINS[c] \"$PREDICATE_LITERAL\""
fi

if [[ "$ERRORS_ONLY" == true ]]; then
    PREDICATE="$PREDICATE AND logType == \"error\""
fi

# Keep arguments as data throughout command construction and execution.
CMD=(log)
if [[ "$PRIVATE" == true ]]; then
    CMD=(sudo -n log)
fi

if [[ "$FOLLOW" == true ]]; then
    STREAM_LEVEL="$LEVEL"
    if [[ "$STREAM_LEVEL" == error ]]; then STREAM_LEVEL=info; fi
    CMD+=(stream --predicate "$PREDICATE" --level "$STREAM_LEVEL")
else
    case $LEVEL in
        debug)
            CMD+=(show --predicate "$PREDICATE" --debug --last "$TIME")
            ;;
        error)
            CMD+=(show --predicate "$PREDICATE" --info --debug --last "$TIME")
            ;;
        *)
            CMD+=(show --predicate "$PREDICATE" --info --last "$TIME")
            ;;
    esac
fi

if [[ "$JSON" == true ]]; then
    CMD+=(--style json)
fi

if [[ -n "$OUTPUT" ]]; then
    if [[ "$NO_TAIL" == true ]]; then
        "${CMD[@]}" > "$OUTPUT"
    else
        "${CMD[@]}" | tail -n "$LINES" > "$OUTPUT"
    fi
else
    if [[ "$NO_TAIL" == true ]]; then
        "${CMD[@]}"
    else
        "${CMD[@]}" | tail -n "$LINES"
    fi
fi
