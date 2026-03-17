# din — D-language Interactive Newsreader

A modern, ncurses-based Usenet reader written in D, inspired by tin/rtin.
Primary design goal: first-class binary support with SSL/TLS connectivity.

---

## Goals

- Connect to modern Usenet providers (SSL/TLS, port 563/443)
- tin-style three-level ncurses TUI (groups → threads → article/reader)
- Unified thread list: multipart binary posts appear as collapsed thread entries alongside text posts
- yEnc decoding, NZB import, par2 repair/verify integration
- Parallel segment downloads with a progress display
- Local header/article cache for fast navigation

---

## Technology Stack

| Concern | Choice | Rationale |
|---|---|---|
| Language | D (LDC or DMD) | Performance, C interop, strong stdlib |
| Build | DUB | Standard D package manager |
| TUI | `deimos/ncurses` (C bindings) | Mature, tin-like control |
| TLS | `openssl` (via `deimos/openssl`) | Universally available, proven |
| Async I/O | `std.socket` + `core.thread.fiber` | Lightweight, no heavy framework |
| yEnc | custom D module | Small enough to own |
| par2 | shell-out to `par2cmdline` binary | Avoid reimplementing RS codes |

---

## Project Structure

```
din/
├── dub.json
├── PLAN.md
├── source/
│   ├── app.d                  # Entry point, arg parsing, config load
│   ├── config.d               # Config file (~/.din/config) read/write
│   ├── nntp/
│   │   ├── client.d           # Core NNTP client (connect, auth, commands)
│   │   ├── tls.d              # TLS wrapper over std.socket via OpenSSL
│   │   ├── commands.d         # NNTP command builders & response parsers
│   │   └── pool.d             # Connection pool for parallel downloads
│   ├── model/
│   │   ├── server.d           # Server config (host, port, user, pass, conns)
│   │   ├── group.d            # Newsgroup metadata
│   │   ├── header.d           # Article header (parsed XOVER fields)
│   │   ├── thread.d           # Thread tree built from References/Subject
│   │   └── binary.d           # BinaryPost: assembled from N header parts
│   ├── cache/
│   │   ├── headerdb.d         # Flat-file header cache per group
│   │   └── grouplist.d        # Subscribed/active group list persistence
│   ├── binary/
│   │   ├── assembler.d        # Groups headers into BinaryPost objects
│   │   ├── yenc.d             # yEnc decoder (single- and multi-part)
│   │   ├── nzb.d              # NZB XML parser → download queue
│   │   └── par2.d             # par2 runner (verify, repair, cleanup)
│   ├── download/
│   │   ├── queue.d            # Download queue state machine
│   │   ├── worker.d           # Fiber-based segment downloader
│   │   └── progress.d         # Progress tracker (bytes, segments, ETA)
│   └── ui/
│       ├── tui.d              # ncurses init/teardown, color pairs, input loop
│       ├── keymap.d           # Key bindings (tin-compatible defaults)
│       ├── screen/
│       │   ├── grouplist.d    # Level 1: subscribed groups screen
│       │   ├── threadlist.d   # Level 2: unified thread+binary list for any group
│       │   ├── article.d      # Level 3: article pager (text) or download confirm (binary)
│       │   └── downloader.d   # Download queue / progress overlay
│       └── widgets/
│           ├── statusbar.d    # Bottom status + key hint bar
│           ├── header.d       # Top title bar
│           └── scrolllist.d   # Generic scrollable list widget
├── test/
│   ├── yenc_test.d
│   ├── assembler_test.d
│   └── nzb_test.d
└── config/
    └── sample.config          # Annotated sample ~/.din/config
```

---

## NNTP Client Design

### Connection & Auth
- Connect via TCP to host:port (default 563 for NNTPS)
- Wrap socket in OpenSSL TLS before any NNTP traffic
- Negotiate: `CAPABILITIES` → check for `AUTHINFO`, `OVER`, `HDR`
- Auth: `AUTHINFO USER` / `AUTHINFO PASS`
- Fall back to plain port 119 if configured (no TLS)

### Key Commands Used
| Command | Purpose |
|---|---|
| `LIST ACTIVE` | Enumerate all groups |
| `GROUP <name>` | Select group, get article range |
| `XOVER <range>` | Bulk fetch headers (number, subject, from, date, msgid, refs, bytes, lines) |
| `BODY <msgid>` | Download a single article body (segment) |
| `ARTICLE <msgid>` | Full article (head + body) for text reading |
| `DATE` | Server time sync |

### Connection Pool (`nntp/pool.d`)
- Configurable N connections (default 8, server-dependent)
- Each connection is a Fiber
- Queue of `SegmentRequest` structs dispatched round-robin to idle connections
- Backpressure: pause queue if disk write queue grows too large

---

## Data Models

### Header (from XOVER)
```d
struct Header {
    long   number;
    string subject;
    string from;
    string date;
    string messageId;
    string references;
    ulong  bytes;
    uint   lines;
}
```

### BinaryPost (assembled from headers)
```d
struct BinaryPost {
    string   baseName;      // Subject stripped of part markers
    uint     totalParts;
    uint     presentParts;
    ulong    totalBytes;
    string[] messageIds;    // indexed by part number
    bool     isComplete;    // presentParts == totalParts
    bool     hasNfo;
    bool     hasPar2;
}
```

### DownloadJob
```d
enum JobState { Queued, Downloading, Decoding, Par2Check, Done, Failed }
struct DownloadJob {
    BinaryPost   post;
    string       destDir;
    JobState     state;
    uint         segmentsDone;
    string[]     decodedFiles;
}
```

---

## Binary Post Assembly (`binary/assembler.d`)

1. Fetch headers for group via XOVER into `Header[]`
2. Regex match subjects for part patterns:
   - `"filename.ext (01/23)"` — classic style
   - `"[1/23]"`, `"[01/23]"`, yEnc subject line patterns
3. Group by normalised base subject + poster
4. Sort parts by part number, record which are present
5. Output `BinaryPost[]` sorted by date descending

**Part-detection regex (examples to handle):**
```
(01/23)   [01/23]   "1 of 23"   yEnc part 1 of 23
```

---

## yEnc Decoder (`binary/yenc.d`)

- Parse `=ybegin`, `=ypart`, `=yend` markers
- Decode body: `byte = (encoded_byte - 42) mod 256`, escape handling for `=`
- Validate CRC32 against `=yend crc32=` field
- Multi-part: accumulate decoded chunks, reassemble in order after all segments downloaded
- Output raw file to configured download directory

---

## NZB Support (`binary/nzb.d`)

- Parse NZB 1.1 XML (std.xml or dxml library)
- Extract `<file>` → `<segments>` → message-IDs
- Construct `DownloadJob` directly from NZB (bypass header fetching)
- Allow drag-and-drop / `:nzb <path>` command in TUI

---

## par2 Integration (`binary/par2.d`)

- Shell out to system `par2` binary (require in PATH)
- After decode: run `par2 verify <par2file>`
- If damaged: run `par2 repair <par2file>`
- Capture stdout/stderr, surface status in TUI download overlay
- Optionally delete par2 files after successful repair (config option)

---

## TUI Design (tin-style)

### Navigation Model
```
[Groups screen]  →  Enter  →  [Thread/Binary list screen]  →  Enter  →  [Article/Download screen]
                 ←  q      ←                               ←  q
```

### Groups Screen (`ui/screen/grouplist.d`)
- One line per subscribed group
- Columns: `flag | group name | unread | total`
- `y` to yank/subscribe, `u` to unsubscribe
- `/` to filter/search groups

### Thread List Screen (`ui/screen/threadlist.d`)
- Single unified view for all groups — no separate "binary mode"
- Text threads: indented reply tree, collapse/expand with `[+]`
- Binary assemblies: appear as a single collapsed entry in the same list
  - Rendered as: `flag | [XX/YY] | filename | poster | age | size`
  - `[XX/YY]` shows present/total parts; colour-coded (green=complete, yellow=partial)
  - `Enter` on a binary entry opens the download confirm prompt (not an article pager)
  - `Enter` on a text thread opens the article pager as normal
- Columns for text entries: `flag | subject | from | date | lines`
- `d` to queue selected binary for download without opening it
- `D` to toggle the download progress overlay

### Article Pager (`ui/screen/article.d`)
- Scrollable body with `j/k` (or arrow keys)
- `s`/`S` to save, `r` to reply (via external editor, `$VISUAL`)
- Pipe to external pager via `|` command

### Download Overlay (`ui/screen/downloader.d`)
- Split-pane or popup showing active download queue
- Per-job: filename, progress bar, speed, ETA, state
- Toggle with `D` from the thread list

### Key Bindings (tin-compatible defaults)
| Key | Action |
|---|---|
| `j`/`k` or `↓`/`↑` | Move selection |
| `Enter`/`→` | Select / drill in |
| `q`/`←` | Back / quit level |
| `g` | Go to group (prompt) |
| `G` | Mark all read |
| `/` | Search |
| `d` | Queue binary download |
| `D` | Toggle download panel |
| `n`/`p` | Next/prev unread |
| `t` | Tag article/binary |
| `T` | Tag all matching pattern |
| `^R` | Refresh headers |
| `?` | Help screen |

---

## Configuration (`~/.din/config`)

INI-style, section per server:

```ini
[server "mynews"]
host     = news.example.com
port     = 563
tls      = true
user     = myuser
pass     = mypass
connections = 8

[options]
download_dir = ~/Downloads/usenet
auto_par2    = true
delete_par2  = true
cache_dir    = ~/.din/cache
max_header_age_days = 30
editor       = $VISUAL
```

---

## Caching Strategy

- One cache file per group per server: `~/.din/cache/<server>/<group.cache>`
- Format: flat binary file — fixed-width records, one per header, appended in article-number order
  - Record: `[ article_number(8) | msgid(128) | from(64) | date(8) | bytes(8) | lines(4) | subject(256) ]`
  - A separate small index file (`<group>.idx`) stores `last_high_watermark` and record count
- On open: read watermark, fetch only `<watermark+1>-<server_high>` via XOVER, append new records
- BinaryPost assembly done in-memory from all cached headers at group-open time
- Evict entire cache file if oldest record exceeds `max_header_age_days` (re-fetch on next open)

---

## Download Pipeline

```
[BinaryPost selected]
        │
        ▼
[DownloadQueue.enqueue(job)]
        │
        ▼
[Pool assigns segments to idle connections]
        │
        ▼  (per segment)
[BODY <msgid>] → raw yEnc text
        │
        ▼
[yenc.decode()] → binary chunk written to temp file
        │
        ▼  (all segments done)
[Assembler joins chunks in part order]
        │
        ▼
[par2 verify / repair if .par2 present]
        │
        ▼
[Move completed files to download_dir]
        │
        ▼
[Job marked Done, temp files cleaned up]
```

---

## DUB Dependencies

```json
{
    "name": "din",
    "description": "D Interactive Newsreader",
    "license": "MIT",
    "dependencies": {
        "deimos-ncurses": "~>1.0",
        "deimos-openssl": "~>3.0",
        "dxml": "~>0.4"
    },
    "libs": ["ncurses", "ssl", "crypto"],
    "buildOptions": ["releaseMode", "optimize"],
    "lflags-osx": ["-L/opt/homebrew/opt/openssl/lib"],
    "includePaths-osx": ["/opt/homebrew/opt/openssl/include"]
}
```

---

## Implementation Phases

### Phase 1 — NNTP Core (no TUI)
- [ ] TLS socket wrapper (`nntp/tls.d`)
- [ ] NNTP client connect/auth/commands (`nntp/client.d`, `nntp/commands.d`)
- [ ] XOVER header fetch and parse
- [ ] Basic config file reader
- [ ] CLI smoke test: connect, fetch 500 headers, print subjects

### Phase 2 — TUI Skeleton
- [ ] ncurses init/teardown (`ui/tui.d`)
- [ ] Scrollable list widget (`ui/widgets/scrolllist.d`)
- [ ] Groups screen (hard-coded test data)
- [ ] Thread list screen (hard-coded test data)
- [ ] Key input loop and navigation

### Phase 3 — Live Data
- [ ] Wire groups screen to real `LIST ACTIVE` / subscribed list
- [ ] Wire thread list to cached XOVER headers
- [ ] Article pager with `ARTICLE` fetch
- [ ] Header cache with flat-file records (`cache/headerdb.d`)

### Phase 4 — Binary Support
- [ ] BinaryPost assembler (`binary/assembler.d`)
- [ ] Binary entry rendering in unified thread list (`ui/screen/threadlist.d`)
- [ ] Download confirm prompt on `Enter` over binary entry
- [ ] yEnc decoder (`binary/yenc.d`)
- [ ] Connection pool (`nntp/pool.d`)
- [ ] Download queue and workers (`download/`)
- [ ] Download progress overlay

### Phase 5 — NZB & par2
- [ ] NZB parser (`binary/nzb.d`)
- [ ] par2 runner (`binary/par2.d`)
- [ ] `:nzb <path>` TUI command

### Phase 6 — Polish
- [ ] Full tin-compatible key bindings
- [ ] Colour themes
- [ ] Resize handling (SIGWINCH)
- [ ] Help screen
- [ ] man page / README

---

## Resolved Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Header cache format | Flat binary file (more unix-y, no extra dep) |
| 2 | Download concurrency | Fibers (lightweight; blocking socket calls wrapped with non-blocking I/O) |
| 3 | Reply/post in v1 | Out of scope |
| 4 | TLS library | OpenSSL via `deimos-openssl` |
| 5 | Binary vs text view | Unified — binary assemblies are entries in the normal thread list, no separate mode |
