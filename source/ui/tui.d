module ui.tui;

import deimos.ncurses;
import std.string : toStringz;

// Color pair IDs — keep in sync with tuiInit.
enum ColorPair : short
{
    Normal   = 0,
    TitleBar = 1,
    StatusBar = 2,
    Selected = 3,
    Unread   = 4,
    Binary   = 5,
    Partial  = 6,
}

void tuiInit()
{
    import core.stdc.locale : setlocale, LC_ALL;
    setlocale(LC_ALL, "");

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, true);
    curs_set(0);

    if (has_colors())
    {
        start_color();
        init_pair(ColorPair.TitleBar,  COLOR_BLACK,  COLOR_CYAN);
        init_pair(ColorPair.StatusBar, COLOR_BLACK,  COLOR_CYAN);
        init_pair(ColorPair.Selected,  COLOR_BLACK,  COLOR_WHITE);
        init_pair(ColorPair.Unread,    COLOR_WHITE,  COLOR_BLACK);
        init_pair(ColorPair.Binary,    COLOR_GREEN,  COLOR_BLACK);
        init_pair(ColorPair.Partial,   COLOR_YELLOW, COLOR_BLACK);
    }
}

void tuiShutdown()
{
    endwin();
}

// Print a D string at (y, x).
void mvprint(int y, int x, string s)
{
    mvaddstr(y, x, s.toStringz);
}

// Fill an entire row with spaces using the given attribute, then restore.
void fillLine(int y, int attr, int cols)
{
    attron(attr);
    mvhline(y, 0, cast(chtype)' ', cols);
    attroff(attr);
}

// Show a transient loading message — no keypress wait, just draw and return.
void showLoading(string msg)
{
    import std.algorithm : min;
    erase();
    int ta = cast(int)(COLOR_PAIR(ColorPair.TitleBar)) | A_BOLD;
    fillLine(0, ta, COLS);
    attron(ta);
    mvprint(0, 2, "din");
    attroff(ta);
    int x = (COLS - cast(int) min(msg.length, cast(size_t) COLS)) / 2;
    if (x < 0) x = 0;
    mvprint(LINES / 2, x, msg);
    refresh();
}

// Show an error message and wait for a keypress.
void showError(string msg)
{
    import std.algorithm : min;
    erase();
    int ta = cast(int)(COLOR_PAIR(ColorPair.TitleBar)) | A_BOLD;
    fillLine(0, ta, COLS);
    attron(ta);
    mvprint(0, 2, "din -- Error");
    attroff(ta);
    int x = (COLS - cast(int) min(msg.length, cast(size_t) COLS)) / 2;
    if (x < 0) x = 0;
    mvprint(LINES / 2, x, msg);
    mvprint(LINES / 2 + 2, (COLS - 21) / 2, "Press any key to continue");
    refresh();
    getch();
}
