# din

> **This project is abandoned.** The implementation reached a working state for
> single-connection header fetching, binary assembly, yEnc decoding, par2
> integration, and NZB import, but the choice of D as the implementation
> language turned out to be a mistake. LDC (the only viable D compiler on Apple
> Silicon) has immature threading support, and D's conservative garbage
> collector interacts badly with C libraries (OpenSSL, ncurses) in ways that
> are very difficult to debug. The final blocker was implementing parallel
> header fetching using OS threads — repeated crashes from malloc double-frees
> and GC interference that we were unable to resolve.

A terminal Usenet reader for people who actually download things.

`din` is a keyboard-driven, ncurses-based newsreader written in D, inspired by
the interface of tin/rtin. It connects to modern Usenet providers over SSL/TLS
and treats binary posts as first-class citizens — multipart uploads appear as
single collapsed entries in the thread list, right alongside regular text posts,
and can be queued for download with a single keypress.

---

## Features

- **Modern server support** — SSL/TLS connections (port 563/443), AUTHINFO,
  and NNTP extensions (`OVER`, `HDR`, `CAPABILITIES`)
- **Unified thread view** — binary assemblies and text threads share the same
  list; no mode-switching, no separate "binary groups"
- **Multipart grouping** — individual segments of a binary post are detected
  and collapsed into one line showing `[12/12]` completion
- **Downloads** — segments are fetched sequentially with a live progress
  overlay; missing or failed segments are skipped so par2 can repair the result
- **yEnc decoding** — single- and multi-part yEnc with CRC32 verification
- **par2 integration** — automatic verify and repair after download if par2
  files are present; shells out to the system `par2` binary
- **NZB import** — load an NZB file directly to bypass header fetching and
  queue a full download immediately
- **Header cache** — fetched headers are stored locally so re-opening a group
  is instant; only new articles are fetched from the server
- **tin-compatible keys** — navigation will feel familiar if you've used tin,
  trn, or slrn

---

## Installation

### Dependencies

- A D compiler: [DMD](https://dlang.org/download.html) or
  [LDC](https://github.com/ldc-developers/ldc/releases) (LDC recommended for
  release builds)
- [DUB](https://dub.pm/) — D package manager (bundled with DMD/LDC)
- OpenSSL (`libssl`, `libcrypto`) — usually already present; on macOS:
  `brew install openssl`
- ncurses — standard on Linux; on macOS it is part of the system SDK
- `par2` — optional, for repair support: `apt install par2` /
  `brew install par2`

### Build

```sh
git clone https://github.com/yourname/din
cd din
dub build -b release
```

The `din` binary will be placed in `./din` (or `bin/din` depending on your
DUB config). Copy it somewhere on your `$PATH`:

```sh
cp din ~/.local/bin/
```

---

## Configuration

On first run `din` looks for `~/.din/config`. If none exists it will prompt
you to create one. The format is INI-style:

```ini
[server "mynews"]
host        = news.example.com
port        = 563
tls         = true
user        = myusername
pass        = mypassword
connections = 8

[options]
download_dir        = ~/Downloads/usenet
auto_par2           = true
delete_par2         = true
cache_dir           = ~/.din/cache
max_header_age_days = 30
editor              = $VISUAL
```

Multiple `[server "..."]` sections are supported. `din` will use the first
one by default; pass `-s servername` on the command line to select another.

---

## Usage

```
din [options]

Options:
  -s <name>     Use named server from config
  -g <group>    Open a specific group directly
  -n <file>     Load an NZB file and start downloading
  -h            Show help
```

### Navigation

`din` has three levels, like tin:

```
Groups  →  Thread list  →  Article / Download
   q ←           q ←
```

#### Groups screen

| Key | Action |
|-----|--------|
| `j` / `k` | Move up/down |
| `Enter` | Open group |
| `y` | Subscribe to group under cursor |
| `u` | Unsubscribe |
| `g` | Go to group (type name) |
| `G` | Mark all articles in group as read |
| `/` | Search group names |
| `^R` | Refresh group list |
| `q` | Quit |

#### Thread list

All groups use the same thread list. Text threads and binary assemblies appear
together. Binary entries show part completion in `[XX/YY]` format and are
colour-coded: green when all parts are present, yellow when partial.

| Key | Action |
|-----|--------|
| `j` / `k` | Move up/down |
| `Enter` | Open article (text) or download prompt (binary) |
| `d` | Queue binary for download without opening |
| `D` | Toggle download progress overlay |
| `t` | Tag entry |
| `T` | Tag all matching a pattern |
| `n` / `p` | Next / previous unread |
| `G` | Mark all read |
| `/` | Search subjects |
| `^R` | Fetch new headers |
| `q` | Back to groups |

#### Article pager

| Key | Action |
|-----|--------|
| `j` / `k` or `Space` / `b` | Scroll down / up |
| `n` / `p` | Next / previous article |
| `s` | Save article to file |
| `\|` | Pipe article to command |
| `q` | Back to thread list |

#### Download overlay

Toggled with `D` from the thread list. Shows all queued, active, and recently
completed jobs with per-job progress bars, speed, and ETA.

---

## Binary Posts

When `din` fetches headers for a group it automatically detects multipart
subject lines — patterns like `filename.part01.rar (1/23)`, `[2/23]`, or yEnc
`part 1 of 23` — and groups the segments together into a single thread-list
entry. The entry shows:

```
 [23/23]  Ubuntu.24.04.iso.part01.rar          poster@host   2d   4.3 GB
```

Pressing `Enter` or `d` on such an entry queues all segments for download.
`din` fetches each segment in order, decodes the yEnc data, and assembles the
parts into the final file. The filename comes from the yEnc `name=` header when
present, falling back to the subject line. If any segments fail, they are
skipped rather than zero-padded — the incomplete file is still useful for
`par2 repair`. After assembly, if `auto_par2 = true`, `din` runs
`par2 verify` and `par2 repair` as needed. Completed files land in
`download_dir`.

### NZB files

```sh
din -n my_download.nzb
```

Or from within din, at any screen: `:nzb /path/to/file.nzb`

NZB import skips header fetching entirely and goes straight to the download
queue, which is useful when headers have aged off the server.

---

## Cache

Headers are cached in `~/.din/cache/<server>/<group>` as flat binary files.
Re-opening a group only fetches articles newer than the stored high-water mark.
Caches for groups you haven't opened in `max_header_age_days` days are
discarded and re-fetched on next open.

---

## License

MIT
