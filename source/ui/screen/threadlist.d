module ui.screen.threadlist;

import std.format    : format;
import std.algorithm : min;
import std.string    : indexOf, toLower;

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
import nntp.pool : NntpPool;

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
                  NntpPool pool, DownloadQueue queue, string destDir)
{
    ScrollList sl;
    sl.reset(cast(int) items.length, startAt);

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
    string formatTextRow(ref ThreadItem item, int cols)
    {
        auto h    = item.header;
        string from = h.from.length > 20 ? h.from[0 .. 20] : h.from;
        string line = format("%7d  %-20s  %s", h.number, from, h.subject);
        if (cast(int) line.length > cols)
            line = line[0 .. cols];
        return line;
    }

    string formatBinaryRow(ref ThreadItem item, int cols)
    {
        auto bp = item.binary;
        string parts = format("[%d/%d]", bp.presentParts, bp.totalParts);
        double mb    = bp.totalBytes / (1024.0 * 1024.0);
        string mbStr = format("%.1f MB", mb);
        string poster = bp.poster.length > 18 ? bp.poster[0 .. 18] : bp.poster;
        string line = format("%-8s  %-18s  %7s  %s",
                             parts, poster, mbStr, bp.baseName);
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
                string line = formatTextRow(item, cols);
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
                string line  = formatBinaryRow(item, cols);
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
            : "j/k:move  g/G:top/bot  /:search  n:next  d:dl  D:queue  A:fetch-all  Enter:open  q:back";
        if (cast(int) hint.length > cols - 2)
            hint = hint[0 .. cols - 2];
        mvprint(rows - 1, 2, hint);
        attroff(sa);

        refresh();
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
                    startDownload(items[sl.selected].binary);
                }
                else
                {
                    redraw("Not a binary.");
                    continue;
                }
                break;
            }

            case Action.ShowDownloader:
                runDownloader(queue);
                break;

            case Action.FetchAll: return -3;
            case Action.Back:     return -1;
            case Action.Quit:     return -2;

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
