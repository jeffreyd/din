module ui.screen.threadlist;

import std.format    : format;
import std.algorithm : min;
import std.string    : indexOf, toLower, strip, startsWith;
import std.path      : expandTilde;
import std.file      : readText, exists, mkdirRecurse;
import std.stdio     : File;

import deimos.ncurses;

import model.group;
import model.header;
import model.binary  : BinaryPost;
import model.thread  : ThreadItem, ItemKind;
import ui.tui;
import ui.keymap;
import ui.widgets.scrolllist;
import download.queue   : DownloadQueue, DownloadJob, JobState;
import ui.screen.downloader : showDownloadProgress, runDownloader;
import nntp.pool   : NntpPool;
import binary.nzb  : parseNzb;
import binary.par2 : runPar2;

// Run the thread-list screen for `group` showing `items` (assembled).
// startAt  : restore cursor to this index (e.g. after returning from article).
// pool     : NNTP connection pool for downloading segments.
// queue    : download queue for tracking jobs this session.
// destDir  : where to save downloaded files.
// Returns:
//   >= 0  : index of selected item (check items[result].kind in app.d)
//   -1    : go back to group list
//   -2    : full quit
int runThreadList(Group group, ThreadItem[] items, int startAt,
                  NntpPool pool, DownloadQueue queue, string destDir,
                  bool autoPar2 = true, bool deletePar2 = false)
{
    ScrollList sl;
    sl.reset(cast(int) items.length, startAt);

    bool[] tagged = new bool[](items.length);

    string lastQuery;

    // -----------------------------------------------------------------------
    // Inline search prompt in the status bar.
    // -----------------------------------------------------------------------
    string promptSearch(string prompt)
    {
        int rows = LINES;
        int statAttr = cast(int) COLOR_PAIR(ColorPair.StatusBar);
        fillLine(rows - 1, statAttr, COLS);
        attron(statAttr);
        mvprint(rows - 1, 0, prompt);
        attroff(statAttr);
        move(rows - 1, cast(int) prompt.length);
        echo();
        curs_set(1);
        refresh();

        string q;
        while (true)
        {
            int c = getch();
            if (c == '\n' || c == KEY_ENTER) break;
            if (c == '\x1b') { q = ""; break; }
            if (c == KEY_BACKSPACE || c == '\x7f' || c == '\b')
            {
                if (q.length > 0)
                {
                    q = q[0 .. $ - 1];
                    int x = cast(int) prompt.length + cast(int) q.length;
                    mvaddch(rows - 1, x, cast(chtype) ' ');
                    move(rows - 1, x);
                    refresh();
                }
                continue;
            }
            if (c >= 32 && c < 127)
                q ~= cast(char) c;
        }
        noecho();
        curs_set(0);
        return q;
    }

    // -----------------------------------------------------------------------
    // Forward search from sl.selected + 1, wrapping around.
    // -----------------------------------------------------------------------
    bool doSearch(string query)
    {
        if (query.length == 0) return false;
        string lq = query.toLower;
        int    n  = cast(int) items.length;
        for (int i = 1; i <= n; i++)
        {
            int  idx  = (sl.selected + i) % n;
            auto item = items[idx];
            string subj = item.kind == ItemKind.Text
                        ? item.header.subject
                        : item.binary.baseName;
            string from = item.kind == ItemKind.Text
                        ? item.header.from
                        : item.binary.poster;
            if (subj.toLower.indexOf(lq) >= 0 ||
                from.toLower.indexOf(lq) >= 0)
            {
                sl.selected = idx;
                sl.ensureVisible();
                return true;
            }
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Download confirm prompt.  Returns true if user said yes.
    // -----------------------------------------------------------------------
    bool confirmDownload(ref BinaryPost bp)
    {
        int rows = LINES;
        int cols = COLS;
        int statAttr = cast(int) COLOR_PAIR(ColorPair.StatusBar);
        fillLine(rows - 1, statAttr, cols);
        attron(statAttr);
        double mb = bp.totalBytes / (1024.0 * 1024.0);
        string prompt = format("Download '%s' (%d/%d parts, %.1f MB)? [y/N]: ",
                               bp.baseName, bp.presentParts, bp.totalParts, mb);
        if (cast(int) prompt.length > cols)
            prompt = prompt[0 .. cols];
        mvprint(rows - 1, 0, prompt);
        attroff(statAttr);
        curs_set(1);
        move(rows - 1, cast(int) prompt.length);
        refresh();
        int ch = getch();
        curs_set(0);
        return (ch == 'y' || ch == 'Y');
    }

    // -----------------------------------------------------------------------
    // Queue and immediately run a download job.
    // -----------------------------------------------------------------------
    void startDownload(ref BinaryPost bp)
    {
        size_t idx = queue.enqueue(bp, destDir);
        ref DownloadJob job = queue.job(idx);
        showDownloadProgress(job, pool);
    }

    // -----------------------------------------------------------------------
    // Render one thread-list row.
    // -----------------------------------------------------------------------
    string formatTextRow(ref ThreadItem item, int cols, bool isTagged)
    {
        auto h    = item.header;
        string tag  = " ";
        string from = h.from.length > 20 ? h.from[0 .. 20] : h.from;
        string line = format("%s%7d  %-20s  %s", tag, h.number, from, h.subject);
        if (cast(int) line.length > cols)
            line = line[0 .. cols];
        return line;
    }

    string formatBinaryRow(ref ThreadItem item, int cols, bool isTagged)
    {
        auto bp = item.binary;
        string tag   = isTagged ? "*" : " ";
        string parts = format("[%d/%d]", bp.presentParts, bp.totalParts);
        double mb    = bp.totalBytes / (1024.0 * 1024.0);
        string mbStr = format("%.1f MB", mb);
        string poster = bp.poster.length > 18 ? bp.poster[0 .. 18] : bp.poster;
        string line = format("%s%-8s  %-18s  %7s  %s",
                             tag, parts, poster, mbStr, bp.baseName);
        if (cast(int) line.length > cols)
            line = line[0 .. cols];
        return line;
    }

    // -----------------------------------------------------------------------
    // Full redraw.
    // -----------------------------------------------------------------------
    void redraw(string statusMsg = "")
    {
        int rows     = LINES;
        int cols     = COLS;
        int listRows = rows - 2;
        sl.rows      = listRows;
        sl.ensureVisible();

        erase();

        // Title bar.
        int ta = cast(int)(COLOR_PAIR(ColorPair.TitleBar)) | A_BOLD;
        fillLine(0, ta, cols);
        attron(ta);
        mvprint(0, 2, format("din -- %s  (%d articles)", group.name, items.length));
        attroff(ta);

        // List rows.
        int end = min(sl.offset + listRows, cast(int) items.length);
        for (int i = sl.offset; i < end; i++)
        {
            int  row  = 1 + sl.rowOf(i);
            auto item = items[i];
            bool sel  = (i == sl.selected);

            if (item.kind == ItemKind.Text)
            {
                string line = formatTextRow(item, cols, false);
                if (sel)
                {
                    int a = cast(int)(COLOR_PAIR(ColorPair.Selected)) | A_BOLD;
                    fillLine(row, a, cols);
                    attron(a); mvprint(row, 0, line); attroff(a);
                }
                else
                {
                    mvprint(row, 0, line);
                }
            }
            else  // Binary
            {
                string line  = formatBinaryRow(item, cols, tagged[i]);
                bool complete = item.binary.isComplete;
                int baseAttr = complete
                    ? cast(int)(COLOR_PAIR(ColorPair.Binary)) | A_BOLD
                    : cast(int)(COLOR_PAIR(ColorPair.Partial)) | A_BOLD;

                if (sel)
                {
                    int a = cast(int)(COLOR_PAIR(ColorPair.Selected)) | A_BOLD;
                    fillLine(row, a, cols);
                    attron(a); mvprint(row, 0, line); attroff(a);
                }
                else
                {
                    attron(baseAttr);
                    mvprint(row, 0, line);
                    attroff(baseAttr);
                }
            }
        }

        // Status bar.
        int sa = cast(int) COLOR_PAIR(ColorPair.StatusBar);
        fillLine(rows - 1, sa, cols);
        attron(sa);
        string hint = statusMsg.length > 0 ? statusMsg
            : "j/k:move  g/G:top/bot  /:search  n:next  t:tag  T:dl-tagged  d:dl  R:raw-dump  D:queue  A:all  :nzb  q:back";
        if (cast(int) hint.length > cols - 2)
            hint = hint[0 .. cols - 2];
        mvprint(rows - 1, 2, hint);
        attroff(sa);

        refresh();
    }

    // -----------------------------------------------------------------------
    // Import an NZB file: parse → confirm → download all files → run par2.
    // -----------------------------------------------------------------------
    void doImportNzb(string path)
    {
        if (!exists(path))
        {
            redraw("NZB not found: " ~ path);
            return;
        }

        BinaryPost[] posts;
        try
        {
            posts = parseNzb(readText(path));
        }
        catch (Exception e)
        {
            showError("NZB parse error: " ~ e.msg);
            return;
        }

        if (posts.length == 0)
        {
            redraw("NZB: no files found.");
            return;
        }

        // Show confirm prompt in the status bar.
        ulong totalBytes;
        foreach (ref bp; posts) totalBytes += bp.totalBytes;
        double mb = totalBytes / (1024.0 * 1024.0);

        {
            int rows = LINES;
            int cols = COLS;
            int sa   = cast(int) COLOR_PAIR(ColorPair.StatusBar);
            fillLine(rows - 1, sa, cols);
            attron(sa);
            string prompt = format("Import %d file(s) (%.1f MB) from NZB? [y/N]: ",
                                   posts.length, mb);
            if (cast(int) prompt.length > cols) prompt = prompt[0 .. cols];
            mvprint(rows - 1, 0, prompt);
            attroff(sa);
            curs_set(1);
            move(rows - 1, cast(int) prompt.length);
            refresh();
            int ch = getch();
            curs_set(0);
            if (ch != 'y' && ch != 'Y') return;
        }

        // Download each file sequentially; no keypress wait between files.
        foreach (ref bp; posts)
        {
            size_t idx = queue.enqueue(bp, destDir);
            ref DownloadJob job = queue.job(idx);
            showDownloadProgress(job, pool, false);
        }

        // Run par2 verify/repair if enabled.
        if (autoPar2)
        {
            showLoading("Running par2 verify/repair...");
            auto par2res = runPar2(destDir, deletePar2);
            if (!par2res.success)
            {
                string msg = "par2 repair failed.";
                if (par2res.output.length > 0)
                    msg ~= "  " ~ par2res.output[$-1];
                showError(msg);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Batch-download all tagged binary entries.
    // -----------------------------------------------------------------------
    void doDownloadTagged()
    {
        BinaryPost[] posts;
        foreach (size_t i, ref item; items)
        {
            if (tagged[i] && item.kind == ItemKind.Binary)
                posts ~= item.binary;
        }

        if (posts.length == 0)
        {
            redraw("No tagged binaries.");
            return;
        }

        ulong totalBytes;
        foreach (ref bp; posts) totalBytes += bp.totalBytes;
        double mb = totalBytes / (1024.0 * 1024.0);

        {
            int rows = LINES;
            int cols = COLS;
            int sa   = cast(int) COLOR_PAIR(ColorPair.StatusBar);
            fillLine(rows - 1, sa, cols);
            attron(sa);
            string prompt = format("Download %d tagged file(s) (%.1f MB)? [y/N]: ",
                                   posts.length, mb);
            if (cast(int) prompt.length > cols) prompt = prompt[0 .. cols];
            mvprint(rows - 1, 0, prompt);
            attroff(sa);
            curs_set(1);
            move(rows - 1, cast(int) prompt.length);
            refresh();
            int ch = getch();
            curs_set(0);
            if (ch != 'y' && ch != 'Y') return;
        }

        foreach (ref bp; posts)
        {
            size_t idx = queue.enqueue(bp, destDir);
            ref DownloadJob job = queue.job(idx);
            showDownloadProgress(job, pool, false);
        }

        if (autoPar2)
        {
            showLoading("Running par2 verify/repair...");
            auto par2res = runPar2(destDir, deletePar2);
            if (!par2res.success)
            {
                string msg = "par2 repair failed.";
                if (par2res.output.length > 0)
                    msg ~= "  " ~ par2res.output[$-1];
                showError(msg);
            }
        }

        // Clear all tags after a confirmed batch.
        foreach (ref t; tagged) t = false;
    }

    // -----------------------------------------------------------------------
    // Raw-dump: fetch every segment of every tagged binary as individual
    // files (full ARTICLE — head + body) so the raw content can be
    // inspected.  Errors produce an empty file with -ERROR appended.
    // -----------------------------------------------------------------------
    void doRawDump()
    {
        import std.path : buildPath;

        BinaryPost[] posts;
        foreach (size_t i, ref item; items)
            if (tagged[i] && item.kind == ItemKind.Binary)
                posts ~= item.binary;

        if (posts.length == 0)
        {
            redraw("No tagged binaries to raw-dump.");
            return;
        }

        foreach (ref bp; posts)
        {
            string dumpDir = buildPath(destDir, bp.baseName ~ "_raw");
            mkdirRecurse(dumpDir);

            string[] msgIds = bp.messageIds;
            int      total  = cast(int) msgIds.length;
            int      done   = 0;

            void showProgress(string extra = "")
            {
                int rows = LINES, cols = COLS;
                int sa = cast(int) COLOR_PAIR(ColorPair.StatusBar);
                fillLine(rows - 1, sa, cols);
                attron(sa);
                string msg = format("Raw dump [%s]: %d/%d  %s",
                                    bp.baseName, done, total, extra);
                if (cast(int) msg.length > cols - 2)
                    msg = msg[0 .. cols - 2];
                mvprint(rows - 1, 2, msg);
                attroff(sa);
                refresh();
            }

            showProgress();

            pool.fetchBodies(msgIds,
                delegate void(size_t idx, string body)
                {
                    string fname = format("seg_%04d.raw", idx + 1);
                    auto f = File(buildPath(dumpDir, fname), "wb");
                    f.rawWrite(cast(const(ubyte)[]) body);
                    f.close();
                    done++;
                    showProgress();
                },
                delegate void(size_t idx, string errMsg)
                {
                    string fname = format("seg_%04d.raw-ERROR", idx + 1);
                    File(buildPath(dumpDir, fname), "wb").close();
                    done++;
                    showProgress(errMsg);
                },
                true   // useArticle: fetch head+body
            );
        }

        redraw(format("Raw dump done (%d file(s))", posts.length));
    }

    redraw();

    while (true)
    {
        int ch = getch();
        switch (keyToAction(ch))
        {
            case Action.Up:       sl.moveUp();    break;
            case Action.Down:     sl.moveDown();  break;
            case Action.PageUp:   sl.pageUp();    break;
            case Action.PageDown: sl.pageDown();  break;
            case Action.Top:      sl.goTop();     break;
            case Action.Bottom:   sl.goBottom();  break;

            case Action.Select:
                if (items[sl.selected].kind == ItemKind.Binary)
                {
                    // Confirm then download.
                    if (confirmDownload(items[sl.selected].binary))
                        startDownload(items[sl.selected].binary);
                }
                else
                {
                    return sl.selected;
                }
                break;

            case Action.Download:
            {
                auto item = items[sl.selected];
                if (item.kind == ItemKind.Binary)
                {
                    startDownload(item.binary);
                }
                else
                {
                    // Not assembled as binary — download the article body directly.
                    BinaryPost bp;
                    bp.baseName     = item.header.subject;
                    bp.poster       = item.header.from;
                    bp.date         = item.header.date;
                    bp.totalParts   = 1;
                    bp.presentParts = 1;
                    bp.isComplete   = true;
                    bp.messageIds   = [item.header.messageId];
                    bp.totalBytes   = item.header.bytes;
                    startDownload(bp);
                }
                break;
            }

            case Action.ShowDownloader:
                runDownloader(queue);
                break;

            case Action.Tag:
            {
                if (items[sl.selected].kind == ItemKind.Binary)
                    tagged[sl.selected] = !tagged[sl.selected];
                sl.moveDown();
                break;
            }

            case Action.DownloadTagged:
                doDownloadTagged();
                break;

            case Action.RawDump:
                doRawDump();
                break;

            case Action.FetchAll: return -3;
            case Action.Back:     return -1;
            case Action.Quit:     return -2;

            case Action.Command:
            {
                string cmd = promptSearch(":").strip;
                if (cmd.startsWith("nzb "))
                    doImportNzb(expandTilde(cmd[4 .. $].strip));
                break;
            }

            case Action.Search:
            {
                string q = promptSearch("/");
                if (q.length > 0)
                {
                    lastQuery = q;
                    if (!doSearch(q))
                    {
                        redraw("Not found: " ~ q);
                        continue;
                    }
                }
                break;
            }

            case Action.SearchNext:
            {
                if (lastQuery.length > 0 && !doSearch(lastQuery))
                {
                    redraw("Not found: " ~ lastQuery);
                    continue;
                }
                break;
            }

            default: break;
        }
        redraw();
    }
}
