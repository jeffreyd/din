module app;

import std.stdio     : writeln, writefln, write, stderr, stdout, File;
import std.getopt    : getopt, defaultGetoptPrinter, GetoptResult;
import std.path      : expandTilde;
import std.algorithm : max, min;
import std.format    : format;
import std.datetime  : Clock, DateTime;

import config;
import model.server   : ServerConfig;
import model.group    : Group;
import model.header   : Header;
import model.thread   : ThreadItem, ItemKind;
import nntp.client    : NntpClient;
import nntp.pool      : NntpPool;
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

        // Fetch / update header cache for this group.
        showLoading("Fetching headers for " ~ group.name ~ " ...");

        Header[] headers;
        try
        {
            headers = syncHeaders(client, cfg, server, group.name);
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
        ThreadItem[] items = assemble(headers);

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
                // User pressed A — fetch all headers from the beginning.
                showLoading("Fetching all headers for " ~ group.name ~ " ...");
                try
                {
                    headers = syncHeaders(client, cfg, server, group.name,
                                         /*fetchAll=*/true);
                }
                catch (Exception e)
                {
                    showError("Error: " ~ e.msg);
                    continue;
                }
                showLoading("Assembling thread list...");
                items = assemble(headers);
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

// Fetch any new headers from the server and merge into the cache.
// Returns all headers for the group (cached + new).
private Header[] syncHeaders(
    NntpClient client, ref AppConfig cfg,
    ref ServerConfig server, string groupName,
    bool fetchAll = false)
{
    string cpath = cachePath(cfg.options.cacheDir, server.name, groupName);
    string ipath = indexPath(cfg.options.cacheDir, server.name, groupName);

    auto idx  = readIndex(ipath);
    auto info = client.selectGroup(groupName);

    long from;
    if (fetchAll)
        from = max(info.first, info.last - 500_000 + 1);
    else if (info.last > idx.watermark)
        from = (idx.watermark > 0)
            ? idx.watermark + 1
            : max(info.first, info.last - 10_000 + 1);  // initial: last 10000
    else
        from = info.last + 1;  // nothing new

    if (from <= info.last)
    {
        enum long batchSize = 50_000L;
        long batchFrom = from;
        while (batchFrom <= info.last)
        {
            long batchTo = min(batchFrom + batchSize - 1, info.last);
            auto fresh = client.fetchHeaders(batchFrom, batchTo);
            appendHeaders(cpath, ipath, fresh);
            batchFrom = batchTo + 1;
        }
    }

    return loadHeaders(cpath);
}
