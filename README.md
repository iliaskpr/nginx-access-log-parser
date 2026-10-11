# nginx-access-log-parser

A bash script that summarizes nginx access logs. It reads the current log and the rotated logs, including gzip files.

## Report

The script prints these sections:

- Summary: log files, log format, start time, requests, unique IPs, 4xx and 5xx rates, data sent
- Top IPs
- Top user agents
- Top paths
- Top domains
- Top status codes
- Top paths by upstream time (average, maximum, request count)
- Top 4xx paths
- Top 5xx paths
- Top referers

Each list counts requests and shows the top N values. The paths do not include the query string. The lists skip empty values and `-`.

## Requirements

- Linux
- bash 4 or later
- GNU coreutils
- awk (gawk or mawk)
- gzip
- nginx (optional), to read the log format from the nginx configuration

The script uses GNU `date -d` and `stat -c`. It does not run with the BSD versions of these tools (macOS).

## Installation

```bash
git clone https://github.com/<user>/nginx-access-log-parser.git
```

```bash
cd nginx-access-log-parser
```

Optional: copy the script to `/usr/local/bin`.

```bash
sudo install -m 755 nginx-access-log-parser.sh /usr/local/bin/nginx-access-log-parser
```

## Usage

```
nginx-access-log-parser.sh [options]
```

| Option | Default | Description |
|---|---|---|
| `-s`, `--since TIME` | `30m` | Start of the time window. |
| `-t`, `--top N` | `10` | Number of rows in each list. |
| `-f`, `--file PATH` | `/var/log/nginx/access.log` | Path of the current access log. |
| `-h`, `--help` | | Show the help. |

`--since` accepts two types of values:

- A relative time: `90s`, `30m`, `2h`, `7d`. A number without a unit is minutes.
- An absolute time: any value that `date -d` accepts, for example `"2026-10-11 08:00"` or `yesterday`.

| Environment variable | Default | Description |
|---|---|---|
| `NGINX_LOG_FORMAT` | none | Log format to use when the script cannot read it from the nginx configuration. See [Log format](#log-format). |
| `NGINX_ACCESS_LOG` | `/var/log/nginx/access.log` | Default value of `--file`. |

### Examples

Show the last 30 minutes, top 10:

```bash
./nginx-access-log-parser.sh
```

Show the last 2 hours, top 20:

```bash
./nginx-access-log-parser.sh --since 2h --top 20
```

Show a different log from a fixed time:

```bash
./nginx-access-log-parser.sh --since "2026-10-11 08:00" --file /var/log/nginx/example.com.access.log
```

### Permissions

Often, only root and a log group can read the nginx logs. On Debian and Ubuntu, this group is `adm`. Also, `nginx -T` usually needs root. Thus, run the script with `sudo`.

`sudo` removes environment variables by default. If you use `NGINX_LOG_FORMAT`, use `sudo -E` to keep it:

```bash
sudo -E ./nginx-access-log-parser.sh --since 1h
```

## Log format

The script gets the log format in this order:

1. The `log_format` of the access log in the nginx configuration
2. The `NGINX_LOG_FORMAT` environment variable
3. The nginx `combined` format

If the script cannot read the format from the nginx configuration, it prints a notice. The notice gives the reason and the format that the script uses:

```
notice: cannot read the log format from the nginx config ("nginx -T" failed, try sudo). Using the NGINX_LOG_FORMAT variable.
```

The "Log format" line of the summary shows the source of the format.

### Format from the nginx configuration

The script reads the full nginx configuration with `nginx -T`. Then it does these steps:

1. It finds the `access_log` directive with the path of `--file`.
2. It gets the format name from this directive. If the directive has no format name, nginx uses `combined`.
3. It finds the `log_format` directive with this name and joins its quoted strings.

The script cannot read the format in these cases:

- The `nginx` command is not available, or `nginx -T` fails. Usually, `nginx -T` needs root.
- No `access_log` directive has the exact path of `--file`. For example, the path contains variables, or nginx runs on a different host.
- The same file has more than one format.
- The `log_format` strings are not in single quotes.

### Domain and upstream time

The `combined` format has no domain and no upstream time:

```
$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"
```

Thus, the "Top domains" and "Top paths by upstream time" sections show no data. To get these sections, add `$host` and `$upstream_response_time` to the nginx configuration:

```nginx
log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                '$status $body_bytes_sent "$http_referer" '
                '"$http_user_agent" $host "$upstream_response_time"';

access_log /var/log/nginx/access.log main;
```

Then reload nginx. The script reads the new format from the configuration. Lines from before the change do not match the new format. The script skips these lines and prints a warning.

### NGINX_LOG_FORMAT

If the script cannot read the nginx configuration, set `NGINX_LOG_FORMAT` to the format of the log. Write it on one line, without the nginx quotes:

```bash
export NGINX_LOG_FORMAT='$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" $host "$upstream_response_time"'
```

To keep the value for new shells, add this line to `~/.bashrc`.

The format from the nginx configuration has priority. Thus, the script ignores `NGINX_LOG_FORMAT` when it can read the configuration.

### Format rules

These rules apply to the format from all sources.


- Put text between two variables. The parser finds the end of a variable at the text that follows it. Thus, `$remote_addr$status` is not valid.
- A value must not contain the text that follows its variable. nginx writes `"` in a value as `\x22`. Thus, variables in quotes are safe.
- Put `$upstream_response_time` in quotes or at the end of the line. With more than one upstream, the value contains spaces, for example `0.010, 0.250`. The script adds these times together.
- JSON formats (`escape=json`) also work.

If a line does not match the format, the script skips the line. At the end, it prints a warning with the number of skipped lines.

### Variables

The script uses these variables. It ignores all other variables.

| Data | Variables |
|---|---|
| Client IP | `$remote_addr` |
| Time | `$time_local` or `$time_iso8601` |
| Path | `$request` or `$request_uri` |
| Status code | `$status` |
| Data sent | `$body_bytes_sent` or `$bytes_sent` |
| Domain | `$host`, `$http_host` or `$server_name` |
| User agent | `$http_user_agent` |
| Referer | `$http_referer` |
| Upstream time | `$upstream_response_time` |

If the format does not have a variable, the related section shows no data. Without a time variable, `--since` selects only the files.

## Rotated logs

The script reads `PATH` and all the files with a name that starts with `PATH`. For `/var/log/nginx/access.log`, it also reads these files:

- `access.log.1`
- `access.log.2.gz`
- `access.log-20261011.gz`

The script decompresses `.gz` files while it reads them. It skips a file if the file has a modification time before the start of the time window. Such a file cannot contain newer requests. Thus, a short time window reads only one or two files.

## Time zone

The script compares the log time with `--since` in the local time zone of the shell. It ignores the UTC offset in the log line. Run the script on the nginx server, or set `TZ` to the time zone of the server.

## Example output

```
$ ./nginx-access-log-parser.sh --top 3
== Summary ==
Log files:     /var/log/nginx/access.log
Log format:    log_format main (nginx config)
Since:         2026-10-11 14:34:45 EEST
Requests:      400
Unique IPs:    30
4xx responses: 88 (22.0%)
5xx responses: 104 (26.0%)
Data sent:     1.0 MB

== Top IPs ==
    164 203.0.113.7
     14 10.0.0.18
     13 10.0.0.12

== Top user agents ==
    102 Googlebot/2.1 (+http://www.google.com/bot.html)
    100 Mozilla/5.0 (X11; Linux x86_64) Firefox/131.0
     90 curl/8.5.0

== Top paths ==
    111 /api/users
     73 /static/app.js
     61 /login

== Top domains ==
    141 api.example.com
    134 shop.example.com
    125 example.com

== Top status codes ==
    156 200
     88 404
     53 502

== Top paths by upstream time ==
 avg (s)  max (s)  requests  path
   4.000    4.000        47  /api/report
   0.971    2.500        86  /api/users
   0.909    2.500        50  /login

== Top 4xx paths ==
     53 404 /wp-login.php
     13 404 /api/users
      7 404 /api/report

== Top 5xx paths ==
     19 502 /api/users
     17 500 /login
     16 500 /api/users

== Top referers ==
    147 https://google.com/
    126 https://example.com/
```

## Exit status

| Code | Meaning |
|---|---|
| `0` | The script printed the report, or it found no requests in the time window. |
| `1` | Error: for example, an incorrect option or a log file that the script cannot read. |
