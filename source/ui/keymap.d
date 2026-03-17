module ui.keymap;

import deimos.ncurses;

enum Action
{
    None,
    Up,
    Down,
    PageUp,
    PageDown,
    Top,
    Bottom,
    Select,
    Back,
    Quit,
    Refresh,
    Help,
    Search,
    SearchNext,
    Download,
    ShowDownloader,
    FetchAll,
}

Action keyToAction(int ch)
{
    switch (ch)
    {
        case 'k': case KEY_UP:                   return Action.Up;
        case 'j': case KEY_DOWN:                 return Action.Down;
        case KEY_PPAGE: case 'b':                return Action.PageUp;
        case KEY_NPAGE: case ' ':                return Action.PageDown;
        case 'g': case KEY_HOME:                 return Action.Top;
        case 'G': case KEY_END:                  return Action.Bottom;
        case '\n': case KEY_ENTER: case KEY_RIGHT: return Action.Select;
        case 'q': case KEY_LEFT:                 return Action.Back;
        case 'Q':                                return Action.Quit;
        case 0x12:                               return Action.Refresh;  // Ctrl-R
        case '?':                                return Action.Help;
        case '/':                                return Action.Search;
        case 'n':                                return Action.SearchNext;
        case 'd':                                return Action.Download;
        case 'D':                                return Action.ShowDownloader;
        case 'A':                                return Action.FetchAll;
        default:                                 return Action.None;
    }
}
