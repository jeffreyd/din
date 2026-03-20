module nntp.headerpool;

import std.algorithm  : min;
import std.format     : format;
import std.file       : exists, mkdirRecurse, remove;
import std.path       : dirName, buildPath;

import core.thread.fiber : Fiber;

import model.server   : ServerConfig;
import nntp.client    : NntpClient;
import nntp.scheduler : FiberScheduler;
import cache.headerdb : CacheAppender, mergeTempFiles;

// ---------------------------------------------------------------------------
// Progress tracking — updated from fibers (cooperative, no locks needed).
// ---------------------------------------------------------------------------

struct HeaderFetchProgress
{
    int  batchesDone;
    int  batchesTotal;
    long articlesFetched;
    int  connections;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// scope(exit) cannot contain try/catch directly in D, so close via helpers.
private void safeClose(NntpClient cl) nothrow
{
    try { cl.close(); } catch (Exception) {}
}

private void safeCloseAppender(ref CacheAppender app) nothrow
{
    try { app.close(); } catch (Exception) {}
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Fetch all articles in [from, to] for groupName using up to N parallel
/// NNTP connections (N = server.connections).  Writes packed CacheRecords
/// directly to per-fiber temp files which are merged into cpath when done.
/// No Header[] is ever heap-allocated.  onProgress is called after each batch.
/// logger (optional) receives diagnostic lines during the fetch.
void fetchHeadersParallel(
    ServerConfig server,
    string groupName,
    long from, long to,
    string cpath, string ipath,
    void delegate(ref HeaderFetchProgress) onProgress,
    void delegate(string) logger = null)
{
    void log(string msg) { if (logger) logger(msg); }

    if (from > to) return;

    int n = server.connections > 0 ? server.connections : 1;

    // Divide [from, to] into n contiguous chunks.
    long total   = to - from + 1;
    long perConn = (total + n - 1) / n;

    struct Chunk { long lo, hi; }
    Chunk[] chunks;
    {
        long cur = from;
        while (cur <= to && cast(int) chunks.length < n)
        {
            long end = min(cur + perConn - 1, to);
            chunks ~= Chunk(cur, end);
            cur = end + 1;
        }
        n = cast(int) chunks.length;
    }

    // One temp file per fiber — written to independently, merged at the end.
    string[] tmpPaths;
    foreach (i; 0 .. n)
        tmpPaths ~= buildPath(dirName(cpath),
                              format("%s.fetch_%d.tmp", groupName, i));

    // Compute total batch count for the progress bar.
    enum long batchSize = 5_000L;
    HeaderFetchProgress prog;
    prog.connections = n;
    foreach (ref c; chunks)
        prog.batchesTotal += cast(int)((c.hi - c.lo) / batchSize + 1);

    // Open one NNTP connection per fiber (blocking, before scheduler starts).
    NntpClient[] clients;
    clients.length = n;
    scope (exit)
        foreach (ref cl; clients)
            if (cl) safeClose(cl);

    foreach (i; 0 .. n)
    {
        log(format("headerpool: opening connection %d / %d", i + 1, n));
        clients[i] = new NntpClient();
        clients[i].connect(server);
        clients[i].setNonBlocking();
        log(format("headerpool: connection %d ready", i + 1));
    }

    // Delete temps on any error so stale files don't pollute the cache.
    scope (failure)
        foreach (tp; tmpPaths)
            if (exists(tp)) try { remove(tp); } catch (Exception) {}

    // Spawn one fiber per connection and run them cooperatively.
    log(format("headerpool: starting %d fibers, %d total batches",
               n, prog.batchesTotal));
    auto sched = new FiberScheduler();
    foreach (ci; 0 .. n)
        sched.addFiber(makeFetchFiber(
            clients[ci], groupName,
            chunks[ci].lo, chunks[ci].hi,
            tmpPaths[ci], batchSize,
            &prog, onProgress, logger));

    sched.run();
    log("headerpool: all fibers done, merging temp files");

    // Merge temp files into the main cache file in range order.
    mergeTempFiles(tmpPaths, cpath, ipath);
    log("headerpool: merge complete");
}

// ---------------------------------------------------------------------------
// Per-fiber worker
// ---------------------------------------------------------------------------

private Fiber makeFetchFiber(
    NntpClient client,
    string groupName,
    long lo, long hi,
    string tmpPath,
    long batchSize,
    HeaderFetchProgress* prog,
    void delegate(ref HeaderFetchProgress) onProgress,
    void delegate(string) logger)
{
    return new Fiber(delegate void()
    {
        void log(string msg) { if (logger) logger(msg); }

        // Wrap the entire fiber body so no exception can escape to the
        // scheduler (which would crash the process via f.call() re-throw).
        try
        {
            log(format("fiber [%d-%d]: selecting group", lo, hi));

            // Select the group first — XOVER requires it on most servers.
            client.selectGroup(groupName);

            log(format("fiber [%d-%d]: group selected, opening temp file", lo, hi));

            string fakeIdx = tmpPath ~ ".idx";
            mkdirRecurse(dirName(tmpPath));
            auto app = CacheAppender.open(tmpPath, fakeIdx);
            scope (exit) safeCloseAppender(app);

            long batchFrom = lo;
            while (batchFrom <= hi)
            {
                long  batchTo  = min(batchFrom + batchSize - 1, hi);
                ulong savedPos = app.filePos();

                try
                {
                    client.fetchHeadersEach(groupName, batchFrom, batchTo,
                        () { app.truncateToPos(savedPos); },
                        (string line)
                        {
                            app.putLine(line);
                            prog.articlesFetched++;
                        });
                }
                catch (Exception e)
                {
                    log(format("fiber [%d-%d]: batch %d-%d error: %s",
                               lo, hi, batchFrom, batchTo, e.msg));
                    app.truncateToPos(savedPos);
                }

                prog.batchesDone++;
                try { onProgress(*prog); } catch (Exception) {}

                batchFrom = batchTo + 1;
            }

            log(format("fiber [%d-%d]: done, %d articles",
                       lo, hi, prog.articlesFetched));
        }
        catch (Throwable t)
        {
            // Catches both Exception and Error (OOM, bounds, assert, etc.)
            // so nothing can escape to the scheduler's f.call().
            log(format("fiber [%d-%d]: fatal: %s", lo, hi, t.msg));
        }
    }, 512 * 1024);
}
