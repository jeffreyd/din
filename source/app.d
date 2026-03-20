module app;

import std.stdio     : writeln, writefln, write, stderr, stdout, File;
import std.getopt    : getopt, defaultGetoptPrinter, GetoptResult;
import std.path      : expandTilde;
import std.algorithm : max, min;
import std.format    : format;
import std.datetime  : Clock, DateTime, SysTime;
import core.memory   : GC;

// ---------------------------------------------------------------------------
// Debug logging — only active when cfg.options.logFile is non-empty.
// Opens the file lazily on first use; appends across calls.
// ---------------------------------------------------------------------------
private File   _logFile;
private string _logPath;

private void dbg(string msg)
{
    if (_logPath.length == 0) return;
    if (!_logFile.isOpen) _logFile = File(_logPath, "a");
    auto ts = cast(DateTime) Clock.currTime();
    _logFile.writefln("[%02d:%02d:%02d] %s",
                      ts.hour, ts.minute, ts.second, msg);
    _logFile.flush();
}

import config;
import model.server   : ServerConfig;
import model.group    : Group;
import model.header   : Header;
import model.thread   : ThreadItem, ItemKind;
import nntp.client      : NntpClient;
import nntp.pool        : NntpPool;
import nntp.headerpool  : fetchHeadersParallel, HeaderFetchProgress;
import nntp.commands  : NntpException, NntpAuthException;
import cache.headerdb;
import cache.grouplist;
import binary.assembler : assemble;
import download.queue   : DownloadQueue;
import ui.tui;
import ui.screen.grouplist  : runGroupList;
import ui.screen.threadlist : runThreadList;
import ui.screen.article    : runArticle;

int main(string[] args)
{
    string configPath = expandTilde("~/.din/config");

    GetoptResult opts;
    try
    {
        opts = getopt(args,
            "c|config", "Config file path", &configPath);
    }
    catch (Exception e)
    {
        stderr.writeln("Error: ", e.msg);
        return 1;
    }

    if (opts.helpWanted)
    {
        defaultGetoptPrinter(
            "din -- D Interactive Newsreader\n\nUsage: din [options]\n",
            opts.options);
        return 0;
    }

    // --- config ---
    auto cfg = loadConfig(configPath);
    _logPath = cfg.options.logFile;   // empty string = logging disabled
    if (cfg.servers.length == 0)
    {
        stderr.writeln("No servers configured.  Create ~/.din/config (see README.md).");
        return 1;
    }
    auto server = cfg.servers[0];

    // --- subscribed groups ---
    string groupsFile = groupsFilePath(cfg.options.cacheDir);
    string[] subscribed = loadSubscribed(groupsFile);
    if (subscribed.length == 0)
    {
        stderr.writefln(
            "No subscribed groups.  Add group names (one per line) to:\n  %s",
            groupsFile);
        return 1;
    }

    // --- connect (main client for headers/articles) ---
    write("Connecting to ", server.host, "...");
    stdout.flush();

    auto client = new NntpClient();
    scope (exit) client.close();

    try
    {
        client.connect(server);
    }
    catch (NntpAuthException e)
    {
        writeln("\nAuthentication failed: ", e.msg);
        return 1;
    }
    catch (NntpException e)
    {
        writeln("\nConnection error: ", e.msg);
        return 1;
    }
    writeln(" OK");

    // --- download pool (separate connection for segment fetching) ---
    // Created lazily on first download to avoid a second TLS handshake at startup.
    NntpPool pool;

    NntpPool getPool()
    {
        if (pool is null)
        {
            showLoading("Opening download connection...");
            pool = new NntpPool(server);
        }
        return pool;
    }

    scope (exit) { if (pool !is null) pool.close(); }

    // --- download queue (session-scoped) ---
    auto queue   = new DownloadQueue();
    string destDir = cfg.options.downloadDir;

    // --- fetch group counts (GROUP command per subscribed group) ---
    write("Checking groups...");
    stdout.flush();

    Group[] groups;
    foreach (name; subscribed)
    {
        try
        {
            auto info = client.selectGroup(name);
            string ipath = indexPath(cfg.options.cacheDir, server.name, name);
            auto   idx   = readIndex(ipath);
            long   unread = (info.last > idx.watermark)
                          ? info.last - idx.watermark
                          : 0;
            groups ~= Group(name, info.count, unread);
        }
        catch (NntpException)
        {
            groups ~= Group(name, 0, 0);   // group unavailable on this server
        }
    }
    writeln(" done");

    // --- TUI ---
    tuiInit();
    scope (exit) tuiShutdown();

    // Declared here so we can explicitly null them before each reload,
    // letting the GC actually reclaim the memory (conservative GC won't
    // collect data that still has a live stack reference).
    Header[]    headers;
    ThreadItem[] items;

    outer: while (true)
    {
        int sel = runGroupList(groups);
        if (sel == -1) break;

        if (sel == -2)
        {
            // X — fetch full group list from server and write to ~/.din/groups.all.YYYY-MM-DD
            showLoading("Fetching full group list from server...");
            try
            {
                auto names = client.fetchGroupList();
                auto now   = cast(DateTime) Clock.currTime();
                string date = format("%04d-%02d-%02d", now.year,
                                     cast(int) now.month, now.day);
                string outPath = expandTilde("~/.din/groups.all." ~ date);
                auto f = File(outPath, "w");
                foreach (n; names)
                    f.writeln(n);
                f.close();
                showError(format("Wrote %d groups to %s", names.length, outPath));
            }
            catch (Exception e)
            {
                showError("Export failed: " ~ e.msg);
            }
            continue;
        }

        auto group = groups[sel];

        // Release any previously loaded group data before fetching new ones.
        headers = null;
        items   = null;
        GC.collect();
        GC.minimize();

        // Fetch / update header cache for this group.
        showLoading("Fetching headers for " ~ group.name ~ " ...");

        try
        {
            dbg("syncHeaders start: " ~ group.name);
            headers = syncHeaders(client, cfg, server, group.name);
            dbg(format("syncHeaders done: %d headers", headers.length));
            groups[sel].unread = 0;
        }
        catch (NntpException e)
        {
            showError("NNTP error: " ~ e.msg);
            continue;
        }
        catch (Exception e)
        {
            showError("Error: " ~ e.msg);
            continue;
        }

        // Assemble headers into unified thread+binary list.
        showLoading("Assembling thread list...");
        dbg(format("assemble start: %d headers", headers.length));
        items = assemble(headers);
        dbg(format("assemble done: %d items", items.length));
        // headers is no longer needed — release before entering the TUI loop
        // so the GC can reclaim ~300 MB while we still hold a named reference.
        headers = null;
        GC.collect();
        GC.minimize();

        int threadCursor = 0;
        while (true)
        {
            int result = runThreadList(group, items, threadCursor,
                                       getPool(), queue, destDir,
                                       cfg.options.autoPar2,
                                       cfg.options.deletePar2);
            if (result == -2) break outer;
            if (result == -1) break;

            if (result == -3)
            {
                // User pressed A — fetch all headers using parallel connections.
                headers = null;
                items   = null;
                GC.collect();
                GC.minimize();

                string cpath = cachePath(cfg.options.cacheDir, server.name, group.name);
                string ipath = indexPath(cfg.options.cacheDir, server.name, group.name);

                auto info = client.selectGroup(group.name);
                clearCache(cpath, ipath);

                dbg("fetchAll parallel start: " ~ group.name);
                try
                {
                    fetchHeadersParallel(server, group.name,
                        info.first, info.last, cpath, ipath,
                        (ref HeaderFetchProgress p) {
                            drawHeaderFetchProgress(group.name, p);
                        },
                        (string s) { dbg(s); });
                }
                catch (Exception e)
                {
                    showError("Fetch error: " ~ e.msg);
                    continue;
                }
                dbg("fetchAll parallel done");

                showLoading("Assembling thread list...");
                headers = loadHeaders(cpath);
                items = assemble(headers);
                headers = null;
                GC.collect();
                GC.minimize();
                continue;
            }

            threadCursor = result;

            auto item = items[result];

            if (item.kind == ItemKind.Binary)
            {
                // Binary entry: download was already handled inside runThreadList
                // (Enter → confirm → download). Nothing to do here; loop back.
                continue;
            }

            // Text entry: open article pager.
            string msgId = item.header.messageId;
            showLoading("Fetching " ~ msgId ~ " ...");

            string text;
            try
            {
                text = client.fetchArticle(msgId);
            }
            catch (NntpException e)
            {
                showError("NNTP error: " ~ e.msg);
                continue;
            }

            int ar = runArticle(msgId, text);
            if (ar == -2) break outer;
        }
    }

    return 0;
}

private void drawHeaderFetchProgress(string groupName,
                                     ref HeaderFetchProgress p)
{
    import std.format    : format;
    import std.algorithm : min;
    import deimos.ncurses;

    erase();

    int ta = cast(int)(COLOR_PAIR(ColorPair.TitleBar)) | A_BOLD;
    fillLine(0, ta, COLS);
    attron(ta);
    mvprint(0, 2, "din -- Fetching Headers");
    attroff(ta);

    mvprint(2, 2, "Group:       " ~ groupName);
    mvprint(3, 2, format("Connections: %d", p.connections));
    mvprint(5, 2, format("Batches:     %d / %d", p.batchesDone, p.batchesTotal));
    mvprint(6, 2, format("Articles:    %d fetched", p.articlesFetched));

    // Progress bar based on batches completed.
    int barWidth = min(COLS - 6, 60);
    if (barWidth > 4 && p.batchesTotal > 0)
    {
        int filled = cast(int)(
            cast(double) p.batchesDone / p.batchesTotal * barWidth);
        string bar = "[";
        foreach (i; 0 .. barWidth)
            bar ~= i < filled ? "=" : " ";
        bar ~= "]";
        mvprint(8, 2, bar);
    }

    // Status bar.
    int sa = cast(int) COLOR_PAIR(ColorPair.StatusBar);
    fillLine(LINES - 1, sa, COLS);

    refresh();
}

// Fetch any new headers from the server and merge into the cache.
// Returns all headers for the group (cached + new).
private Header[] syncHeaders(
    NntpClient client, ref AppConfig cfg,
    ref ServerConfig server, string groupName)
{
    GC.collect();   // release any previously loaded headers before this sync

    string cpath = cachePath(cfg.options.cacheDir, server.name, groupName);
    string ipath = indexPath(cfg.options.cacheDir, server.name, groupName);

    auto idx  = readIndex(ipath);
    auto info = client.selectGroup(groupName);

    long from;
    if (info.last > idx.watermark)
        from = (idx.watermark > 0)
            ? idx.watermark + 1
            : max(info.first, info.last - 10_000 + 1);  // initial: last 10000
    else
        from = info.last + 1;  // nothing new

    if (from <= info.last)
    {
        enum long batchSize = 5_000L;
        auto appender = CacheAppender.open(cpath, ipath);
        long batchFrom = from;
        int  batchNum  = 0;
        while (batchFrom <= info.last)
        {
            long batchTo   = min(batchFrom + batchSize - 1, info.last);
            ulong savedPos = appender.filePos();
            dbg(format("XOVER batch %d: %d..%d", batchNum, batchFrom, batchTo));
            long lineCount = 0;
            client.fetchHeadersEach(groupName, batchFrom, batchTo,
                () { appender.truncateToPos(savedPos); lineCount = 0; },
                (string line) { appender.putLine(line); lineCount++; });
            dbg(format("XOVER batch %d: got %d lines", batchNum, lineCount));
            batchFrom = batchTo + 1;
            batchNum++;
        }
        appender.close();
    }

    dbg("loadHeaders start: " ~ cpath);
    auto result = loadHeaders(cpath);
    dbg(format("loadHeaders done: %d records", result.length));
    return result;
}
