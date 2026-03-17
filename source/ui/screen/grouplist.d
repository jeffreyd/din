module ui.screen.grouplist;

import std.format    : format;
import std.algorithm : min;

import deimos.ncurses;

import model.group;
import ui.tui;
import ui.keymap;
import ui.widgets.scrolllist;

// Run the group-list screen.  Returns the index of the selected group,
// or -1 if the user wants to quit the application.
int runGroupList(Group[] groups)
{
    ScrollList sl;
    sl.reset(cast(int) groups.length);

    void redraw()
    {
        int rows     = LINES;
        int cols     = COLS;
        int listRows = rows - 2;     // title bar row 0, status bar row rows-1
        sl.rows      = listRows;
        sl.ensureVisible();

        erase();

        // --- title bar ---
        int titleAttr = cast(int)(COLOR_PAIR(ColorPair.TitleBar)) | A_BOLD;
        fillLine(0, titleAttr, cols);
        attron(titleAttr);
        mvprint(0, 2, "din -- Newsgroups");
        attroff(titleAttr);

        // --- group rows ---
        int end = min(sl.offset + listRows, cast(int) groups.length);
        for (int i = sl.offset; i < end; i++)
        {
            int  row = 1 + sl.rowOf(i);
            auto g   = groups[i];

            string flag = g.unread > 0 ? "*" : " ";
            string line = format("%s %-50s %6d / %-6d",
                                 flag, g.name, g.unread, g.total);
            if (cast(int) line.length > cols)
                line = line[0 .. cols];

            if (i == sl.selected)
            {
                int a = cast(int)(COLOR_PAIR(ColorPair.Selected)) | A_BOLD;
                fillLine(row, a, cols);
                attron(a);
                mvprint(row, 0, line);
                attroff(a);
            }
            else if (g.unread > 0)
            {
                int a = cast(int)(COLOR_PAIR(ColorPair.Unread)) | A_BOLD;
                attron(a);
                mvprint(row, 0, line);
                attroff(a);
            }
            else
            {
                mvprint(row, 0, line);
            }
        }

        // --- status bar ---
        int statAttr = cast(int) COLOR_PAIR(ColorPair.StatusBar);
        fillLine(rows - 1, statAttr, cols);
        attron(statAttr);
        mvprint(rows - 1, 2, "j/k:move  g/G:top/bot  Enter:open  q:quit");
        attroff(statAttr);

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
            case Action.Select:   return sl.selected;
            case Action.Back:
            case Action.Quit:     return -1;
            default:              break;
        }
        redraw();
    }
}
