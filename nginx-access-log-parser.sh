#!/usr/bin/env bash
#
# Summarize nginx access logs, including rotated and gzipped files.
#
# Usage: ./nginx-access-log-parser.sh --since 1h --top 20

set -eu

# Byte-based sort and awk. Faster and safe for any input.
export LC_ALL=C

# nginx is often in /usr/sbin, which is not in the PATH of normal users.
PATH="$PATH:/usr/sbin:/usr/local/sbin"

# nginx default "combined" format.
DEFAULT_LOG_FORMAT='$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"'

LOG_FILE="${NGINX_ACCESS_LOG:-/var/log/nginx/access.log}"
SINCE="30m"
TOP=10

usage() {
  cat <<'EOF'
Usage: nginx-access-log-parser.sh [options]

Options:
  -s, --since TIME   Start of the time window. Default: 30m
                     Relative: 90s, 30m, 2h, 7d (a number alone is minutes).
                     Absolute: any value of "date -d", e.g. "2026-10-11 08:00".
  -t, --top N        Number of rows in each list. Default: 10
  -f, --file PATH    Access log. Rotated files (PATH.1, PATH.2.gz,
                     PATH-20261011.gz) are read too.
                     Default: /var/log/nginx/access.log
  -h, --help         Show this help.

Log format:
  The script reads the log_format of the access log from the nginx config
  ("nginx -T"). If this fails, it uses NGINX_LOG_FORMAT or, if that is not
  set, the nginx "combined" format.

Environment:
  NGINX_LOG_FORMAT   Log format to use when the nginx config is not readable.
  NGINX_ACCESS_LOG   Default value of --file.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Stop when an option has no value.
need_value() {
  if [ -z "${2:-}" ]; then
    die "$1 needs a value"
  fi
}

# Convert --since to epoch seconds.
since_to_epoch() {
  local since="$1"
  local amount unit seconds

  if [[ "$since" =~ ^([0-9]+)([smhd]?)$ ]]; then
    amount="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      s) seconds=$amount ;;
      h) seconds=$((amount * 3600)) ;;
      d) seconds=$((amount * 86400)) ;;
      *) seconds=$((amount * 60)) ;;
    esac
    echo $(($(date +%s) - seconds))
  else
    date -d "$since" +%s
  fi
}

# Print all log lines. Decompress .gz files on the fly.
read_logs() {
  local file
  for file in "${LOG_FILES[@]}"; do
    if [[ "$file" == *.gz ]]; then
      zcat "$file"
    else
      cat "$file"
    fi
  done
}

# Read the log_format of LOG_FILE from the nginx config ("nginx -T").
# On success, set FORMAT_NAME and FORMAT_TEXT. On failure, set DETECT_ERROR and return 1.
detect_log_format() {
  local config file names

  if ! command -v nginx > /dev/null; then
    DETECT_ERROR="nginx command not found"
    return 1
  fi

  if ! config=$(nginx -T 2>/dev/null); then
    DETECT_ERROR="\"nginx -T\" failed, try sudo"
    return 1
  fi

  # The config has absolute paths.
  file=$(realpath -s "$LOG_FILE")

  # Format names of the access_log lines for this file. No name means "combined".
  names=$(awk -v file="$file" '
    $1 == "access_log" && ($2 == file || $2 == file ";") {
      name = $3
      sub(/;$/, "", name)
      if (name == "") name = "combined"
      print name
    }' <<< "$config" | sort -u)

  if [ -z "$names" ]; then
    DETECT_ERROR="no access_log for $file"
    return 1
  fi

  if [ "$(wc -l <<< "$names")" -gt 1 ]; then
    DETECT_ERROR="$file has more than one log_format: $(paste -sd ' ' <<< "$names")"
    return 1
  fi

  FORMAT_NAME="$names"

  # "combined" is built into nginx, so it is not in the config.
  if [ "$FORMAT_NAME" = "combined" ]; then
    FORMAT_TEXT="$DEFAULT_LOG_FORMAT"
    return 0
  fi

  # Join the quoted strings of "log_format NAME", up to the ";" at the end.
  FORMAT_TEXT=$(awk -v name="$FORMAT_NAME" '
    $1 == "log_format" && $2 == name { found = 1 }
    found && $1 ~ /^#/ { next }
    found {
      line = $0
      # \047 is a single quote.
      while (match(line, /\047[^\047]*\047/)) {
        printf "%s", substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
      sub(/#.*/, "", line)
      if (line ~ /;/) exit
    }' <<< "$config")

  if [ -z "$FORMAT_TEXT" ]; then
    DETECT_ERROR="cannot read log_format $FORMAT_NAME"
    return 1
  fi
}

# Parse log lines with LOG_FORMAT. Print one tab-separated row per request:
#   1 ip | 2 status | 3 path | 4 domain | 5 user agent | 6 referer | 7 bytes | 8 upstream time
parse_logs() {
  awk -v log_format="$LOG_FORMAT" -v since="$SINCE_STAMP" '
    # Split the format into tokens: variables ($status) and the text between them.
    function parse_format(format,    count) {
      count = 0
      while (format != "") {
        count++
        if (match(format, /^\$[a-zA-Z0-9_]+/)) {
          is_var[count] = 1
          token[count] = substr(format, 2, RLENGTH - 1)
          has[token[count]] = 1
        } else {
          # Text up to the next "$". A lone "$" is text too.
          if (!match(format, /^[^$]+/)) {
            RLENGTH = 1
          }
          is_var[count] = 0
          token[count] = substr(format, 1, RLENGTH)
        }
        format = substr(format, RLENGTH + 1)
      }
      return count
    }

    # Fill field[name] from one log line. A variable ends where the next text starts.
    # Return 0 if the line does not match the format.
    function parse_line(line,    i, pos) {
      delete field
      for (i = 1; i <= token_count; i++) {
        if (!is_var[i]) {
          if (substr(line, 1, length(token[i])) != token[i]) {
            return 0
          }
          line = substr(line, length(token[i]) + 1)
        } else if (i == token_count) {
          field[token[i]] = line
        } else {
          pos = index(line, token[i + 1])
          if (pos == 0) {
            return 0
          }
          field[token[i]] = substr(line, 1, pos - 1)
          line = substr(line, pos)
        }
      }
      return 1
    }

    # "11/Oct/2026:10:15:32 +0000" -> "20261011101532"
    function local_time_stamp(t) {
      return substr(t, 8, 4) month[substr(t, 4, 3)] substr(t, 1, 2) substr(t, 13, 2) substr(t, 16, 2) substr(t, 19, 2)
    }

    # "2026-10-11T10:15:32+00:00" -> "20261011101532"
    function iso_time_stamp(t) {
      t = substr(t, 1, 19)
      gsub(/[^0-9]/, "", t)
      return t
    }

    # Sum all upstream tries: "0.010, 0.250" -> 0.26. Empty when there is no upstream ("-").
    function upstream_seconds(value,    parts, count, i, total, found) {
      count = split(value, parts, /[ ,:]+/)
      total = 0
      found = 0
      for (i = 1; i <= count; i++) {
        if (parts[i] ~ /^[0-9.]+$/) {
          total += parts[i]
          found = 1
        }
      }
      if (found) {
        return total
      }
      return ""
    }

    BEGIN {
      OFS = "\t"
      split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", names, " ")
      for (i = 1; i <= 12; i++) {
        month[names[i]] = sprintf("%02d", i)
      }
      token_count = parse_format(log_format)
    }

    {
      if (!parse_line($0)) {
        unparsed++
        next
      }

      # Skip requests before --since.
      if (has["time_local"] && local_time_stamp(field["time_local"]) < since) next
      if (has["time_iso8601"] && iso_time_stamp(field["time_iso8601"]) < since) next

      # Path without the query string.
      if (has["request"]) {
        split(field["request"], parts, " ")
        path = parts[2]
      } else {
        path = field["request_uri"]
      }
      sub(/\?.*/, "", path)

      domain = field["host"]
      if (domain == "") domain = field["http_host"]
      if (domain == "") domain = field["server_name"]

      bytes = field["body_bytes_sent"]
      if (bytes == "") bytes = field["bytes_sent"]

      print field["remote_addr"], field["status"], path, domain, field["http_user_agent"], field["http_referer"], bytes, upstream_seconds(field["upstream_response_time"])
    }

    END {
      if (unparsed > 0) {
        print "warning: " unparsed " lines do not match the log format" > "/dev/stderr"
      }
    }
  '
}

# Print a titled list. Print the note (or "no data") when the list is empty.
print_section() {
  local title="$1"
  local rows="$2"
  local note="${3:-no data}"

  echo
  echo "== $title =="
  if [ -n "$rows" ]; then
    echo "$rows"
  else
    echo "  $note"
  fi
}

# Most frequent values of one column. Empty and "-" values are skipped.
top_column() {
  awk -F '\t' -v column="$1" '$column != "" && $column != "-" { print $column }' "$DATA_FILE" \
    | sort | uniq -c | sort -rn | head -n "$TOP"
}

# Most frequent "status path" pairs for one status class (4 or 5).
top_error_paths() {
  awk -F '\t' -v class="$1" 'substr($2, 1, 1) == class && $3 != "" { print $2, $3 }' "$DATA_FILE" \
    | sort | uniq -c | sort -rn | head -n "$TOP"
}

# Paths with the highest average upstream time.
slowest_paths() {
  local rows
  rows=$(awk -F '\t' '
    $8 != "" && $3 != "" {
      count[$3]++
      total[$3] += $8
      if ($8 > max[$3]) max[$3] = $8
    }
    END {
      for (path in count) {
        printf "%8.3f %8.3f %9d  %s\n", total[path] / count[path], max[path], count[path], path
      }
    }' "$DATA_FILE" | sort -rn | head -n "$TOP")

  if [ -n "$rows" ]; then
    printf "%8s %8s %9s  %s\n" "avg (s)" "max (s)" "requests" "path"
    echo "$rows"
  fi
}

print_summary() {
  local label="Log files:"
  local file

  echo "== Summary =="
  for file in "${LOG_FILES[@]}"; do
    printf "%-14s %s\n" "$label" "$file"
    label=""
  done
  echo "Log format:    $FORMAT_SOURCE"
  echo "Since:         $SINCE_HUMAN"
  awk -F '\t' '
    {
      requests++
      ips[$1] = 1
      bytes += $7
      if ($2 ~ /^4/) client_errors++
      if ($2 ~ /^5/) server_errors++
    }
    END {
      for (ip in ips) unique_ips++
      printf "Requests:      %d\n", requests
      printf "Unique IPs:    %d\n", unique_ips
      printf "4xx responses: %d (%.1f%%)\n", client_errors, client_errors * 100 / requests
      printf "5xx responses: %d (%.1f%%)\n", server_errors, server_errors * 100 / requests
      printf "Data sent:     %.1f MB\n", bytes / 1024 / 1024
    }' "$DATA_FILE"
}

# --- Options ---

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--since)
      need_value "$@"
      SINCE="$2"
      shift 2
      ;;
    -t|--top)
      need_value "$@"
      TOP="$2"
      shift 2
      ;;
    -f|--file)
      need_value "$@"
      LOG_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (see --help)"
      ;;
  esac
done

if ! [[ "$TOP" =~ ^[1-9][0-9]*$ ]]; then
  die "--top must be a positive number"
fi

if [ ! -f "$LOG_FILE" ]; then
  die "cannot access log file: $LOG_FILE"
fi

SINCE_EPOCH=$(since_to_epoch "$SINCE" 2>/dev/null) || die "invalid --since value: $SINCE"
SINCE_STAMP=$(date -d "@$SINCE_EPOCH" +%Y%m%d%H%M%S)
SINCE_HUMAN=$(date -d "@$SINCE_EPOCH" '+%Y-%m-%d %H:%M:%S %Z')

# --- Log format ---

# Order: nginx config, then NGINX_LOG_FORMAT, then the default "combined" format.
if detect_log_format; then
  LOG_FORMAT="$FORMAT_TEXT"
  FORMAT_SOURCE="log_format $FORMAT_NAME (nginx config)"
elif [ -n "${NGINX_LOG_FORMAT:-}" ]; then
  LOG_FORMAT="$NGINX_LOG_FORMAT"
  FORMAT_SOURCE="NGINX_LOG_FORMAT variable"
  echo "notice: cannot read the log format from the nginx config ($DETECT_ERROR). Using the NGINX_LOG_FORMAT variable." >&2
else
  LOG_FORMAT="$DEFAULT_LOG_FORMAT"
  FORMAT_SOURCE="default combined format"
  echo "notice: cannot read the log format from the nginx config ($DETECT_ERROR). Using the default combined format. Export NGINX_LOG_FORMAT to change it." >&2
fi

# The parser finds the end of a variable by the text after it.
if [[ "$LOG_FORMAT" =~ \$[a-zA-Z0-9_]+\$ ]]; then
  die "log format: each variable must be followed by text, not by another variable"
fi

if [[ "$LOG_FORMAT" != *'$time_local'* && "$LOG_FORMAT" != *'$time_iso8601'* ]]; then
  echo "warning: the log format has no \$time_local or \$time_iso8601, --since only filters files" >&2
fi

# --- Log files ---

# Current log plus rotated logs. Skip files not modified since the start of the window.
LOG_FILES=()
for file in "$LOG_FILE"*; do
  if [ ! -f "$file" ]; then
    continue
  fi
  if [ "$(stat -c %Y "$file")" -lt "$SINCE_EPOCH" ]; then
    continue
  fi
  if [ ! -r "$file" ]; then
    die "cannot read $file (try sudo)"
  fi
  LOG_FILES+=("$file")
done

if [ ${#LOG_FILES[@]} -eq 0 ]; then
  echo "No log files modified since $SINCE_HUMAN"
  exit 0
fi

# --- Report ---

DATA_FILE=$(mktemp)
trap 'rm -f "$DATA_FILE"' EXIT

read_logs | parse_logs > "$DATA_FILE"

if [ ! -s "$DATA_FILE" ]; then
  echo "No requests since $SINCE_HUMAN"
  exit 0
fi

print_summary
print_section "Top IPs" "$(top_column 1)"
print_section "Top user agents" "$(top_column 5)"
print_section "Top paths" "$(top_column 3)"
print_section "Top domains" "$(top_column 4)" "no data: add \$host to the log format"
print_section "Top status codes" "$(top_column 2)"
print_section "Top paths by upstream time" "$(slowest_paths)" "no data: add \$upstream_response_time to the log format"
print_section "Top 4xx paths" "$(top_error_paths 4)"
print_section "Top 5xx paths" "$(top_error_paths 5)"
print_section "Top referers" "$(top_column 6)"
