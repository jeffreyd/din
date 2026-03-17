# din — Claude session context

## What this project is

`din` is a terminal Usenet newsreader written in D, inspired by tin/rtin.
See README.md for the user-facing description and PLAN.md for the full
architecture plan.  The binary must be named `din`.

## Toolchain

- Compiler: **LDC 1.42.0** (`/opt/homebrew/bin/ldc2`) — installed via Homebrew
- Build tool: **DUB 1.41.0** (`/opt/homebrew/bin/dub`) — installed via Homebrew
- The old DMD installation at `~/dlang/dmd-2.112.0/` is x86-only and crashes
  on this arm64 machine.  Do not use it.  Always use the Homebrew ldc2/dub.

## Current build status

Phase 1 source files are all written but the build has not yet succeeded.
The error seen was `Failed to allocate memory (Cannot allocate memory)` from
dub — this appeared immediately after installing the new toolchain and may be
a transient issue (DUB initialising its package cache for the first time).
**First thing to do in the next session: run `dub build --compiler=ldc2` and
diagnose from whatever output comes back.**

The `openssl` DUB package (v3.4.0) was already fetched successfully.
`dxml` has not been fetched yet but DUB will pull it automatically on build.

## Files written so far

```
.gitignore
dub.json
PLAN.md
README.md
config/sample.config
source/app.d
source/config.d
source/model/server.d
source/model/header.d
source/nntp/commands.d
source/nntp/tls.d
source/nntp/client.d
```

Everything else in the planned source tree is still a stub / not yet created.

## Key architectural decisions (from PLAN.md)

1. Header cache: flat binary file per group (no SQLite)
2. Download concurrency: Fibers
3. Reply/post: out of scope for v1
4. TLS: OpenSSL via `deimos/openssl` (DUB package name: `"openssl"`)
5. Binary view: there is NO separate binary-group mode — binary assemblies
   (multipart yEnc posts) appear as collapsed entries in the normal thread
   list, exactly like threads.  Entering one opens a download prompt.

## Implementation phases

- **Phase 1** (in progress): NNTP core — TLS socket, client, config, smoke-test CLI
- Phase 2: ncurses TUI skeleton (groups + thread list screens, hard-coded data)
- Phase 3: live data wired to TUI + flat-file header cache
- Phase 4: binary assembly, yEnc decoder, download queue/workers, progress overlay
- Phase 5: NZB import, par2 integration
- Phase 6: polish (resize, colour themes, help screen, man page)

## DUB package names

- OpenSSL bindings: `"openssl": "~>3.3"` (imports `deimos.openssl.ssl` etc.)
- NZB XML parsing: `"dxml": "~>0.4"`
- ncurses bindings: TBD — to be added when Phase 2 starts (do not add yet)

## macOS build notes

- OpenSSL is from Homebrew: `/opt/homebrew/opt/openssl@3/`
- `dub.json` already has the lflags for both arm64 (`/opt/homebrew/...`) and
  Intel (`/usr/local/...`) Homebrew paths.

## Coding conventions

- D module names match file paths (e.g. `source/nntp/tls.d` → `module nntp.tls;`)
- Exceptions are in `nntp/commands.d`: `NntpException`, `NntpAuthException`
- `TlsSocket` is in `nntp/tls.d`; `NntpClient` uses it from `nntp/client.d`
- `SSL_set_tlsext_host_name` is a C macro — `tls.d` implements it locally via
  `SSL_ctrl` with constants `SSL_CTRL_SET_TLSEXT_HOSTNAME=55` and
  `TLSEXT_NAMETYPE_host_name=0`
- No reply/post support in v1
- Keep code simple; avoid over-engineering
