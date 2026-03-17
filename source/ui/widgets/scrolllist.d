module ui.widgets.scrolllist;

import std.algorithm : min, max;

struct ScrollList
{
    int rows;      // visible rows available for items
    int total;     // total number of items
    int selected;  // selected index (absolute)
    int offset;    // scroll offset: index of first visible item

    void reset(int total_, int startAt = 0)
    {
        total    = total_;
        selected = (startAt > 0 && startAt < total_) ? startAt : 0;
        offset   = selected;   // ensureVisible() will correct this in redraw
    }

    // Clamp offset so that selected is always on screen.
    // Call once per redraw after setting sl.rows.
    void ensureVisible()
    {
        if (rows <= 0) return;
        if (selected < offset)
            offset = selected;
        if (selected >= offset + rows)
            offset = selected - rows + 1;
        if (offset < 0) offset = 0;
    }

    void goTop()
    {
        selected = 0;
        offset   = 0;
    }

    void goBottom()
    {
        selected = total > 0 ? total - 1 : 0;
        offset   = max(0, total - rows);
    }

    bool moveDown()
    {
        if (selected >= total - 1) return false;
        ++selected;
        if (selected >= offset + rows)
            ++offset;
        return true;
    }

    bool moveUp()
    {
        if (selected <= 0) return false;
        --selected;
        if (selected < offset)
            --offset;
        return true;
    }

    void pageDown()
    {
        selected = min(selected + rows, total - 1);
        offset   = max(0, selected - rows + 1);
    }

    void pageUp()
    {
        selected = max(selected - rows, 0);
        offset   = min(offset, selected);
    }

    // Screen row (relative to list area top, 0-based) for absolute index i.
    int rowOf(int i) const { return i - offset; }
}
