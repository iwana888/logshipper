# logshipper

A tiny, dependency-light log shipper: **read local log files → push to Loki**.
Written in Free Pascal (FPC), only relying on the FPC/Lazarus RTL
(`fphttpclient`, `zlib`/`zstream`, `BaseUnix`/`Windows`, `fpjson`, `RegExpr`).
No Promtail-style pipeline stages, service discovery, multi-tenancy, or metrics.

## Why

Two app instances write logs to local disk; we just need them in one Loki for
Grafana. Promtail is overkill for this. `logshipper` does exactly one thing.

## Build

Requires FPC >= 3.2.

```sh
# Linux
./build.sh
# or: fpc -Mobjfpc -Sh -O2 -Fu. logshipper.lpr

# Windows
build.bat
```

Output: `logshipper` (Linux) / `logshipper.exe` (Windows).

> On Linux the program `uses` `cmem` + `cthreads` so `TThread` has a working
> thread manager and a thread-safe heap — this is required for the multi-thread
> model and is already in `logshipper.lpr`.

> HTTPS to Loki works out of the box (`opensslsockets` in `uloki.pas`); see
> [HTTPS push (optional)](#https-push-optional) for the runtime DLL requirements.

## Run

```sh
./logshipper /etc/logshipper/logshipper.ini
# no arg => looks for ./logshipper.ini
```

Process model: **single process, one reader thread + N sender threads**
(producer/consumer with a push pool).

- **Reader thread** (own `TThread`, not the main thread): polls the matched files,
  reads new lines, parses timestamp + level, and enqueues them into a bounded
  in-memory queue. It **never blocks on the network**, so tailing is never stalled
  by a slow/unreachable Loki. The main thread is only a scheduler that waits for
  the workers to finish.
- **Sender pool** (`sender_threads`, default 2, see `[agent]`): each sender is its
  own thread with its **own** HTTP client. They drain the shared queue concurrently
  and push to Loki with gzip + retry/backoff. All blocking HTTP I/O and retries
  happen in these threads; they cannot delay reading. More senders => more
  concurrent pushes, raising throughput past what one HTTP connection sustains.
  On shutdown the pool drains whatever remains in the queue.

The queue is bounded by `buffer_max_lines`; when full, the reader stops reading
(offsets are not advanced, so nothing is lost) and logs a warning — this is the
backpressure that protects memory under a Loki outage or a log spike.

One `logshipper` process per host, regardless of how many app instances or log
directories live on it. `[agent].instance` is the default Loki label for that
host; when several app instances share the machine, use `[files].instances` to
give each log directory its own label instead of starting more processes.
No hot-reload — change config and restart.

### Deploy as a service

- **Linux (systemd)**: copy `logshipper` + `logshipper.ini` to `/opt/logshipper`,
  drop `logshipper.service` into `/etc/systemd/system`, then
  `systemctl enable --now logshipper`. `SIGTERM` triggers a graceful drain.
- **Windows**: wrap `logshipper.exe` with a service helper (e.g. `nssm` or
  `sc.exe create`) running `logshipper.exe C:\logshipper\logshipper.ini`.
  `Ctrl-C` / service-stop raises the same graceful shutdown.

## Configuration

See `logshipper.ini` for the full annotated template. Highlights:

| Section | Key | Meaning |
|---|---|---|
| `loki` | `url` | `POST /loki/api/v1/push` endpoint |
| `loki` | `token` | optional `Authorization: Bearer` |
| `loki` | `gzip` | gzip-compress the body (default on) |
| `loki` | `timeout_ms` | per-request timeout (default 5000) |
| `agent` | `job`,`instance` | fixed low-cardinality labels; **`instance` differs per host** (per-path overrides: `[files].instances`) |
| `agent` | `poll_interval_ms` | reader loop tick |
| `agent` | `sender_threads` | push pool size (default 2; each has its own HTTP client) |
| `agent` | `batch_max_lines` / `_bytes` / `_delay_ms` | batch flush triggers |
| `agent` | `buffer_max_lines` | in-memory cap → backpressure (never drop) |
| `agent` | `log_file` | optional own status log; if set, messages are also written here (stderr always stays full). Auto-excluded from `paths` so it is never tailed back in |
| `agent` | `log_file_level` | levels written to `log_file`: `error` (**default**, only ERROR), `warn`, `info` (all, incl. the `pushed N lines` heartbeat). Never filters the console |
| `agent` | `log_file_max_bytes` | rotate the status log at this size (default 10 MiB; 0 = never rotate) |
| `agent` | `log_file_max_files` | rotated copies to keep (default 5) |
| `files` | `paths` | `;` separated globs; **only uncompressed logs** — never match `*.gz` (see Limitations) |
| `files` | `instances` | optional `;` separated `instance` labels, **one per `paths` entry**; omit to use `[agent].instance` for every path |
| `files` | `positions_file` | `{path,inode,offset}` store (atomic write) |
| `files` | `max_line_bytes` | truncate lines longer than this |
| `timestamp` | `formats` | `;` separated, tried in order; strptime-style (`%Y %m %d %H %M %S %y %b %B %p`) auto-translated to FPC tokens, matched anywhere in the line. Separator-free forms also work: `%Y%m%d %H%M%S` parses mORMot TSynLog lines like `20261013 09201729  "4 info  ...` (the trailing 2 digits are hundredths of a second and are ignored, giving 1 s precision) |
| `timestamp` | `tz` | `local` (default: parsed wall-clock is local, converted to UTC) or `utc` (leading timestamp already UTC). If a log's leading timestamp differs from an in-message timestamp by the host UTC offset, set `utc` or events land hours off in Loki |
| `timestamp` | `level_regex` | TRegExpr expression; capture group 1 (or the whole match) becomes the `level` label, empty means no label. `(?i)` is supported. For TSynLog: `(?i)^\d{8}\s+\d{8}\s+\S+\s+(INFO\|WARN\|ERROR\|DEBUG\|TRACE\|EXC\|ROTAT)` — the 3rd field is a varying 1–2 char thread marker, so anchor on the date/time instead |
| `timestamp` | `max_age_hours` | timestamps older than this (or >1h in the future) are reset to read-time so a single old line can't make Loki reject the whole batch (default 168 = 7 days, matching Loki). Raise it (and Loki's `reject_old_samples_max_age`) to keep older real times |

### Multiple log directories

`paths` may list any number of globs, separated by `;`. One reader thread
handles all of them — no extra process or thread per directory is needed:

```ini
[files]
paths=C:\logs\01\*.log;C:\logs\02\*.log;C:\logs\03\*.log
instances=app-01;app-02;app-03
```

- File identity is the **full path**, so `01\logs\server.log` and
  `02\logs\server.log` are separate files with separate `{path,inode,offset}`
  entries in `positions.json`.
- Polling is fair: each round reserves a slice of the `buffer_max_lines` budget
  for every matched file and resumes after the last file visited. A large
  backlog in `01` cannot starve `02`/`03`.
- A glob matching nothing (missing directory, instance not deployed yet) logs a
  throttled WARN; a locked/unreadable file is isolated to that file only.
- `instances` is optional and must have exactly one entry per `paths` entry, in
  the same order. Omit it and every file uses `[agent].instance`. Keep instance
  names low-cardinality — never use request, hotel or trace ids.
- Streams are keyed by `(job, instance, level)`, so lines from different app
  instances never share a stream or a monotonic timestamp clock.

### Built-in web viewer

The binary can serve the log query page and proxy Loki API calls itself, so you
do **not** need to run `web/serve.py` (Python) separately.

```ini
[http]
listen=127.0.0.1:8099
```

- One background thread hosts the page and forwards `/loki/*` to the Loki URL
  already configured for pushing (`[loki].url`). It is same-origin, so the
  browser never calls Loki directly (Loki sends no CORS headers).
- Routes: `/` (the viewer page), `/api/info` (returns `{"loki": ...}`),
  `/loki/<path>` (reverse-proxied to `<loki-url>/<path>`).
- The page is read from `web/index.html` next to the executable; if that file
  is missing, a minimal built-in page is served instead.
- Default bind is `127.0.0.1` (localhost only). Change to e.g. `0.0.0.0:8099`
  to expose it on the network. Leave `listen` empty to disable the server.
- No authentication is added — keep it behind localhost or a reverse proxy with
  auth if the network is untrusted.

### HTTPS push (optional)

`url=https://...` works. The SSL handler is registered by `opensslsockets` in
`uloki.pas`; no config switch is needed. On Windows the runtime DLLs must sit
**next to `logshipper.exe`**:

- `libssl-3.dll` + `libcrypto-3.dll` (MSVC build, e.g. the copies shipped with
  Python in its `DLLs\` directory), or
- `libssl-3-x64.dll` + `libcrypto-3-x64.dll` (mingw build, e.g. Git for
  Windows `mingw64\bin\`; these also need their mingw runtime DLLs), or
- `libssl-1_1-x64.dll` + `libcrypto-1_1-x64.dll` (OpenSSL 1.1).

Keep the **original file names** — `libssl-3.dll` imports `libcrypto-3.dll`, so
renaming a DLL to satisfy FPC 3.2.2's 1.1-era defaults breaks the import table.
`uloki.pas` detects the deployed pair at startup and points FPC at it.
On Linux, `libssl.so.3` / `libcrypto.so.3` (or 1.1) must be installed; the
unit extends FPC 3.2.2's version list to include `.so.3`.
Plain `http://` needs none of this and never loads OpenSSL.

## Behaviour map to the spec

- **FR-1** lines read verbatim; `>max_line_bytes` truncated with `...[truncated]`.
- **FR-2** positions persisted as `{path,inode,offset}`, written via temp+rename
  after every successful (or dropped) batch.
- **FR-3** rotation (`rename+new`) and truncation (`copytruncate`) detected via
  `stat` inode / size comparison; old fd is drained to EOF before switching.
- **FR-4** batch on first of: 100 lines / 256 KiB / 2 s; order preserved.
- **FR-5** timestamp parsed (`%Y-%m-%d %H:%M:%S` style, `unix_s`, `unix_ms`; matched
  anywhere in the line, not just the start — a leading `[INFO]` prefix is fine);
  a parsed value whose year is implausible (`<2000` or `>2100`, e.g. an ID/metric
  mistaken for a unix-ms timestamp) is rejected and the line falls back to read-time;
  fallback = read time; per-stream timestamps forced monotonically
  (`prev+1ns`) with a warning.
- **FR-6** labels `job`, `instance`, `level` only (low cardinality).
- **FR-7** grouped by label set into multiple `stream` objects; gzip + bearer
  auth supported; 5 s timeout.
- **FR-8** retry on 429/5xx/network with exponential backoff `1→2→4→8→16→30s`
  (capped, infinite); offset does not advance during retries; other 4xx are
  dropped (offset advances). Buffer cap blocks reading (backpressure). Each
  sender thread owns its own HTTP client, so retries are isolated per-push.
- **FR-9** `SIGTERM`/`SIGINT` (or Windows stop) stops reads, wakes the sender
  pool, lets it drain the queue, then exits. Positions are saved by each sender
  after each successful (or dropped) batch.

## Loki stream labels & Grafana

Streams are keyed by `(job, instance, level)`. In Grafana:

```logql
{job="myapp", instance="app-1"}
{job="myapp", instance="app-1", level="error"}
```

`instance` distinguishes hosts (or, with `[files].instances`, app instances on
one host); `level` is optional. Do **not**
add high-cardinality fields (timestamps, trace ids, line numbers) as labels —
they stay in the log line text.

## Acceptance scenarios

The implementation targets all 12 acceptance criteria in the spec (crash
recovery, Loki outage replay, rotation/truncation, oversized lines, missing
timestamps, per-instance isolation, 400-drop / 429-retry, graceful exit, and
positions-file write failures).

## Notes / assumptions

- Parsed `%Y-%m-%d %H:%M:%S` timestamps are treated as **local time** by default
  and converted to UTC for Loki (set `tz=utc` in `[timestamp]` only if your logs
  are already UTC but the host runs in another zone). `unix_s`/`unix_ms` are
  absolute and need no conversion.
- A crash in the narrow window between draining a rotated-away file and the
  successful push could replay those few lines (at-least-once); this matches the
  spec's "no loss, allow minor duplicates" guarantee.
- The shipper writes its own status to **stderr in full** always. When
  `log_file` is set, only messages at/above `log_file_level` (default `error`)
  are also persisted to that file. So with the default, the file contains only
  errors and stays quiet during healthy operation — which also means it has **no
  heartbeat**: to tell whether the process is alive, check the console /
  systemd journal, or set `log_file_level=info` to keep `pushed N lines` in the
  file.

## Limitations

- **No compressed-log ingestion (no decompress-and-send).** The reader opens files
  as raw (uncompressed) text and tails them by file descriptor + byte offset — it
  does **not** decompress `.gz` / `.zip` / etc. If a `paths` glob accidentally
  matches a compressed rotation (e.g. `app*` also catching
  `app.1.gz`), the compressed bytes are read as garbage and would pollute
  Loki. Configure `paths` to match only the live, uncompressed log (e.g.
  `*.log`), never the compressed rotations. The compressed rotated files were
  already shipped while the log was live, so skipping them loses nothing.
  (One-shot backfill of historical `.gz` archives is out of scope for now; a
  separate decompress-and-read mode would be needed for that.)
