module nntp.headerpool;

import std.algorithm  : min;
import std.format     : format;
import std.file       : exists, mkdirRecurse, remove;
import std.path       : dirName, buildPath;

import core.thread    : Thread;
import core.atomic    : atomicLoad, atomicOp, atomicStore;
import core.time      : dur;
import core.memory    : GC;

import model.server   : ServerConfig;
import nntp.client    : NntpClient;
import cache.headerdb : CacheAppender, mergeTempFiles;

// ---------------------------------------------------------------------------
// Progress tracking
// ---------------------------------------------------------------------------

struct HeaderFetchProgress
{
    int  batchesDone;
    int  batchesTotal;
    long articlesFetched;
    int  connections;
}

// ---------------------------------------------------------------------------
// Per-thread context — one heap-allocated instance per thread so each
// delegate captures a distinct object.  Avoids LDC closure-capture bugs
// where loop-local variables share a single frame across all iterations.
// ---------------------------------------------------------------------------

private final class ThreadCtx
{
    NntpClient client0;   // pre-opened connection for attempt 0
    long       lo, hi;    // article range for this thread
    string     tmpPath;   // temp file path for this thread

    this(NntpClient c, long lo, long hi, string tp)
    {
        this.client0 = c;
        this.lo      = lo;
        this.hi      = hi;
        this.tmpPath = tp;
    }
}

// ---------------------------------------------------------------------------
// Heap-allocated shared state — written by workers, read by main thread.
// ---------------------------------------------------------------------------

private final class FetchState
{
    shared int  batchesDone;
    shared long articlesFetched;
    shared int  totalFailures;
    shared bool abort;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

    long total   = to - from + 1;
    long perConn = (total + n - 1) / n;

    long[] los, his;
    {
        long cur = from;
        while (cur <= to && cast(int) los.length < n)
        {
            long end = min(cur + perConn - 1, to);
            los ~= cur;
            his ~= end;
            cur = end + 1;
        }
        n = cast(int) los.length;
    }

    string[] tmpPaths;
    foreach (i; 0 .. n)
        tmpPaths ~= buildPath(dirName(cpath),
                              format("%s.fetch_%d.tmp", groupName, i));

    enum long batchSize = 5_000L;
    int batchesTotal = 0;
    foreach (i; 0 .. n)
        batchesTotal += cast(int)((his[i] - los[i]) / batchSize + 1);

    auto state = new FetchState();

    // Open connections serially from the main thread — avoids concurrent TLS init.
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
        log(format("headerpool: connection %d ready", i + 1));
    }

    scope (failure)
        foreach (tp; tmpPaths)
        {
            if (exists(tp)) try { remove(tp); } catch (Exception) {}
            string idx = tp ~ ".idx";
            if (exists(idx)) try { remove(idx); } catch (Exception) {}
        }

    log(format("headerpool: starting %d threads, %d total batches", n, batchesTotal));

    // Disable the GC while threads run to prevent stop-the-world signals
    // from interfering with thread startup on macOS.
    GC.disable();
    scope (exit) { GC.enable(); GC.collect(); }

    Thread[] threads;
    threads.length = n;

    foreach (ci; 0 .. n)
    {
        // One ThreadCtx per iteration — each delegate captures its own ctx
        // reference, so there is no shared mutable loop-variable capture.
        auto ctx = new ThreadCtx(clients[ci], los[ci], his[ci], tmpPaths[ci]);

        threads[ci] = new Thread(delegate void()
        {
            int  attempt             = 0;
            int  localBatchesDone    = 0;
            long localArticlesFetched = 0;

            while (attempt < 3)
            {
                if (atomicLoad(state.abort)) return;

                // Clear the temp file before each retry.
                if (attempt > 0)
                {
                    try { if (exists(ctx.tmpPath)) remove(ctx.tmpPath); } catch (Exception) {}
                    string idxTmp = ctx.tmpPath ~ ".idx";
                    try { if (exists(idxTmp)) remove(idxTmp); } catch (Exception) {}
                    log(format("thread [%d-%d]: retry %d", ctx.lo, ctx.hi, attempt));
                }

                try
                {
                    NntpClient client;
                    if (attempt == 0)
                    {
                        client = ctx.client0;
                        log(format("thread [%d-%d]: selecting group", ctx.lo, ctx.hi));
                        client.selectGroup(groupName);
                    }
                    else
                    {
                        log(format("thread [%d-%d]: reconnecting", ctx.lo, ctx.hi));
                        client = new NntpClient();
                        client.connect(server);
                        client.selectGroup(groupName);
                    }
                    scope (exit) { if (attempt > 0) safeClose(client); }

                    mkdirRecurse(dirName(ctx.tmpPath));
                    auto app = CacheAppender.open(ctx.tmpPath, ctx.tmpPath ~ ".idx");
                    scope (exit) safeCloseAppender(app);

                    long batchFrom = ctx.lo;
                    while (batchFrom <= ctx.hi)
                    {
                        if (atomicLoad(state.abort)) return;

                        long  batchTo  = min(batchFrom + batchSize - 1, ctx.hi);
                        ulong savedPos = app.filePos();

                        client.fetchHeadersEach(groupName, batchFrom, batchTo,
                            () { app.truncateToPos(savedPos); },
                            (string line)
                            {
                                app.putLine(line);
                                atomicOp!"+="(state.articlesFetched, 1L);
                                localArticlesFetched++;
                            });

                        atomicOp!"+="(state.batchesDone, 1);
                        localBatchesDone++;
                        batchFrom = batchTo + 1;
                    }

                    log(format("thread [%d-%d]: done", ctx.lo, ctx.hi));
                    return;  // success
                }
                catch (Throwable t)
                {
                    log(format("thread [%d-%d]: attempt %d failed: %s",
                               ctx.lo, ctx.hi, attempt + 1, t.msg));

                    // Roll back this attempt's contribution to shared counters.
                    atomicOp!"-="(state.batchesDone,     localBatchesDone);
                    atomicOp!"-="(state.articlesFetched, localArticlesFetched);
                    localBatchesDone     = 0;
                    localArticlesFetched = 0;

                    attempt++;
                    int totalFails = atomicOp!"+="(state.totalFailures, 1);
                    if (attempt >= 3 || totalFails >= 3)
                    {
                        log(format("thread [%d-%d]: triggering abort (totalFails=%d)",
                                   ctx.lo, ctx.hi, totalFails));
                        atomicStore(state.abort, true);
                        return;
                    }
                }
            }
        }, 8 * 1024 * 1024);
        threads[ci].start();
    }

    // Progress polling — onProgress (ncurses) called only from this thread.
    HeaderFetchProgress prog;
    prog.connections  = n;
    prog.batchesTotal = batchesTotal;

    while (true)
    {
        prog.batchesDone     = atomicLoad(state.batchesDone);
        prog.articlesFetched = atomicLoad(state.articlesFetched);
        try { onProgress(prog); } catch (Throwable) {}

        bool anyAlive = false;
        foreach (t; threads)
            if (t.isRunning) { anyAlive = true; break; }
        if (!anyAlive) break;

        Thread.sleep(dur!"msecs"(100));
    }

    foreach (t; threads) t.join();

    prog.batchesDone     = atomicLoad(state.batchesDone);
    prog.articlesFetched = atomicLoad(state.articlesFetched);
    try { onProgress(prog); } catch (Throwable) {}

    if (atomicLoad(state.abort))
        throw new Exception("Header fetch failed: too many connection errors (see log)");

    log("headerpool: all threads done, merging temp files");
    mergeTempFiles(tmpPaths, cpath, ipath);
    log("headerpool: merge complete");
}
