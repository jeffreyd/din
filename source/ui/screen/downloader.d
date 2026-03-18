module ui.screen.downloader;

import std.format    : format;
import std.algorithm : min;
import std.conv      : to;

import deimos.ncurses;

import ui.tui;
import ui.keymap;
import nntp.pool          : NntpPool;
import download.queue     : DownloadQueue, DownloadJob, JobState;
import download.worker    : runJob;
import download.progress  : SegmentProgress;

// ---------------------------------------------------------------------------
// Blocking download with a live progress screen.
// Returns when the download is complete or failed.
// ---------------------------------------------------------------------------
void showDownloadProgress(ref DownloadJob job, NntpPool pool,
                          bool waitForKey = true)
{
    void redraw()
    {
        int rows = LINES;
        int cols = COLS;

        erase();

        // Title bar.
        int ta = cast(int)(COLOR_PAIR(ColorPair.TitleBar)) | A_BOLD;
        fillLine(0, ta, cols);
        attron(ta);
        string title = "din -- Downloading";
        mvprint(0, 2, title);
        attroff(ta);

        // Filename.
        string fname = job.post.baseName;
        if (cast(int) fname.length > cols - 2)
            fname = fname[0 .. cols - 2];
        mvprint(2, 2, fname);

        // Progress info.
        auto p = job.progress.snapshot();

        string segLine = p.segsError > 0
            ? format("  Segments : %d / %d  (%d missing)", p.segsDone, p.segsTotal, p.segsError)
            : format("  Segments : %d / %d", p.segsDone, p.segsTotal);
        mvprint(4, 0, segLine);

        double mb      = p.bytesDone  / (1024.0 * 1024.0);
        string sizeLine = p.bytesTotal > 0
            ? format("  Size     : %.1f MB / %.1f MB", mb, p.bytesTotal / (1024.0 * 1024.0))
            : format("  Size     : %.1f MB / ? MB", mb);
        mvprint(5, 0, sizeLine);

        string speedLine;
        if (p.bytesPerSec > 0)
            speedLine = format("  Speed    : %.1f MB/s", p.bytesPerSec / (1024.0 * 1024.0));
        else
            speedLine = "  Speed    : --";
        mvprint(6, 0, speedLine);

        string etaLine;
        if (p.etaSecs > 0)
        {
            int secs = cast(int) p.etaSecs;
            etaLine = format("  ETA      : %dm %ds", secs / 60, secs % 60);
        }
        else
        {
            etaLine = "  ETA      : --";
        }
        mvprint(7, 0, etaLine);

        // Progress bar.
        int barWidth = min(cols - 4, 60);
        if (barWidth > 4 && p.bytesTotal > 0)
        {
            int filled = cast(int)(cast(double) p.bytesDone / p.bytesTotal * barWidth);
            string bar = "[";
            foreach (i; 0 .. barWidth)
                bar ~= (i < filled) ? "=" : " ";
            bar ~= "]";
            mvprint(9, 2, bar);
        }

        // State line.
        string stateLine;
        final switch (job.state)
        {
            case JobState.Queued:      stateLine = "Queued";      break;
            case JobState.Downloading: stateLine = "Downloading..."; break;
            case JobState.Decoding:    stateLine = "Writing file..."; break;
            case JobState.Done:
                stateLine = "Done!  Saved to: " ~ (job.decodedFiles.length > 0
                    ? job.decodedFiles[0] : job.destDir);
                break;
            case JobState.Failed:
                stateLine = "FAILED: " ~ job.error;
                break;
        }
        if (cast(int) stateLine.length > cols - 2)
            stateLine = stateLine[0 .. cols - 2];
        mvprint(11, 2, stateLine);

        // Status bar.
        int sa = cast(int) COLOR_PAIR(ColorPair.StatusBar);
        fillLine(rows - 1, sa, cols);
        if (job.state == JobState.Done || job.state == JobState.Failed)
        {
            attron(sa);
            mvprint(rows - 1, 2, "Press any key to continue");
            attroff(sa);
        }

        refresh();
    }

    // Run the download, redrawing after each segment.
    runJob(job, pool, &redraw);

    // Final redraw; only wait for a keypress in single-file mode.
    redraw();
    if (waitForKey) getch();
}

// ---------------------------------------------------------------------------
// Job history / queue browser.  Shows all jobs; press q/D to dismiss.
// ---------------------------------------------------------------------------
void runDownloader(DownloadQueue queue)
{
    void redraw()
    {
        int rows = LINES;
        int cols = COLS;
        erase();

        int ta = cast(int)(COLOR_PAIR(ColorPair.TitleBar)) | A_BOLD;
        fillLine(0, ta, cols);
        attron(ta);
        mvprint(0, 2, format("din -- Downloads (%d jobs)", queue.length));
        attroff(ta);

        auto jobs    = queue.jobs();
        int listRows = rows - 2;
        int end      = min(cast(int) jobs.length, listRows);

        foreach (i; 0 .. end)
        {
            auto j = jobs[i];
            auto p = j.progress.snapshot();

            string stateStr;
            final switch (j.state)
            {
                case JobState.Queued:      stateStr = "Queued   "; break;
                case JobState.Downloading: stateStr = "Fetching "; break;
                case JobState.Decoding:    stateStr = "Writing  "; break;
                case JobState.Done:        stateStr = "Done     "; break;
                case JobState.Failed:      stateStr = "FAILED   "; break;
            }

            string extra = "";
            if (j.state == JobState.Done)
                extra = format("  %.1f MB", cast(double) p.bytesDone / (1024.0 * 1024.0));
            else if (j.state == JobState.Failed)
                extra = "  " ~ j.error;

            string name = j.post.baseName;
            string line = stateStr ~ " " ~ name ~ extra;
            if (cast(int) line.length > cols)
                line = line[0 .. cols];

            int attr;
            if (j.state == JobState.Failed)
                attr = cast(int)(COLOR_PAIR(ColorPair.Partial)) | A_BOLD;
            else if (j.state == JobState.Done)
                attr = cast(int)(COLOR_PAIR(ColorPair.Binary)) | A_BOLD;
            else
                attr = 0;

            if (attr) attron(attr);
            mvprint(1 + i, 0, line);
            if (attr) attroff(attr);
        }

        if (jobs.length == 0)
            mvprint(LINES / 2, (COLS - 17) / 2, "No downloads yet.");

        int sa = cast(int) COLOR_PAIR(ColorPair.StatusBar);
        fillLine(rows - 1, sa, cols);
        attron(sa);
        mvprint(rows - 1, 2, "D/q:close");
        attroff(sa);

        refresh();
    }

    redraw();

    while (true)
    {
        int ch = getch();
        auto action = keyToAction(ch);
        if (action == Action.Quit || action == Action.Back ||
            action == Action.ShowDownloader)
            break;
        redraw();
    }
}
