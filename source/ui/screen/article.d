module ui.screen.article;

import std.string    : splitLines;
import std.algorithm : min, max;

import deimos.ncurses;

import ui.tui;
import ui.keymap;

// Display an article (head + body text) in a scrollable pager.
// Returns -1 to go back to thread list, -2 for full quit.
int runArticle(string title, string text)
{
    auto lines  = splitLines(text);
    int  offset = 0;

    void redraw()
    {
        int rows     = LINES;
        int cols     = COLS;
        int bodyRows = rows - 2;

        erase();

        // title bar
        int ta = cast(int)(COLOR_PAIR(ColorPair.TitleBar)) | A_BOLD;
        fillLine(0, ta, cols);
        attron(ta);
        string t = cast(int) title.length > cols - 4 ? title[0 .. cols - 4] : title;
        mvprint(0, 2, t);
        attroff(ta);

        // article lines
        int end = min(offset + bodyRows, cast(int) lines.length);
        for (int i = offset; i < end; i++)
        {
            string line = lines[i];
            if (cast(int) line.length > cols) line = line[0 .. cols];
            mvprint(1 + i - offset, 0, line);
        }

        // status bar
        int sa = cast(int) COLOR_PAIR(ColorPair.StatusBar);
        fillLine(rows - 1, sa, cols);
        attron(sa);
        mvprint(rows - 1, 2, "j/k:scroll  Space/PgDn:page  q:back  Q:quit");
        attroff(sa);

        refresh();
    }

    redraw();

    while (true)
    {
        int bodyRows = LINES - 2;
        int maxOff   = max(0, cast(int) lines.length - bodyRows);

        int ch = getch();
        switch (keyToAction(ch))
        {
            case Action.Down:
                if (offset < maxOff) offset++;
                break;
            case Action.Up:
                if (offset > 0) offset--;
                break;
            case Action.PageDown:
                offset = min(offset + bodyRows, maxOff);
                break;
            case Action.PageUp:
                offset = max(0, offset - bodyRows);
                break;
            case Action.Back:  return -1;
            case Action.Quit:  return -2;
            default:           break;
        }
        redraw();
    }
}
