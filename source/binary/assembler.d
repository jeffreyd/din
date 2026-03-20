module binary.assembler;

import std.algorithm : sort, canFind;
import std.array     : appender;
import std.string    : strip, toLower, indexOf;
import std.conv      : to, ConvException;
import std.regex     : regex, matchFirst, matchAll, Regex;

import model.header : Header;
import model.binary : BinaryPost;
import model.thread : ThreadItem, ItemKind;

/// Parse all headers and return a unified, article-number-ordered list of
/// ThreadItems.  Multi-part binary subjects are collapsed into BinaryPost
/// entries; everything else becomes a plain Text entry.
ThreadItem[] assemble(Header[] headers)
{
    // -----------------------------------------------------------------------
    // Regex: match (N/M) or [N/M] anywhere in the subject.
    // -----------------------------------------------------------------------
    static Regex!char partRe;
    static bool partReReady;
    if (!partReReady)
    {
        partRe      = regex(`[\[\(](\d{1,4})\s*/\s*(\d{1,4})[\]\)]`);
        partReReady = true;
    }

    // -----------------------------------------------------------------------
    // Intermediate accumulator per binary group.
    // -----------------------------------------------------------------------
    struct PartEntry
    {
        uint   partNum;
        string messageId;
        ulong  bytes;
        long   articleNum;
    }

    struct BinaryGroup
    {
        string       baseName;
        string       poster;
        string       date;
        uint         totalParts;
        long         firstArticleNum = long.max;
        PartEntry[]  parts;
    }

    BinaryGroup[string] groupMap;   // key = normBaseName + '\0' + normPoster
    ThreadItem[]        textItems;

    foreach (ref h; headers)
    {
        // Find all (N/M) / [N/M] tokens and pick the one with the largest M.
        // Some subjects carry both a collection indicator like [2/4] and a
        // per-file segment counter like (50/52).  matchFirst would grab the
        // first token, leaving the other in the base name and breaking grouping.
        size_t bestPre    = 0;
        size_t bestHit    = 0;
        uint   partNum    = 0;
        uint   totalParts = 0;
        bool   foundMatch = false;

        foreach (m2; matchAll(h.subject, partRe))
        {
            uint pn, tp;
            try { pn = m2[1].to!uint; tp = m2[2].to!uint; }
            catch (ConvException) { continue; }
            if (pn == 0 || tp == 0 || pn > tp) continue;
            if (!foundMatch || tp > totalParts)
            {
                bestPre    = m2.pre.length;
                bestHit    = m2.hit.length;
                partNum    = pn;
                totalParts = tp;
                foundMatch = true;
            }
        }

        if (!foundMatch)
        {
            textItems ~= ThreadItem(ItemKind.Text, h);
            continue;
        }

        // Strip the best-matched token from the subject to derive the base name.
        string pre  = h.subject[0 .. bestPre].strip;
        string post = h.subject[bestPre + bestHit .. $].strip;
        string base = (pre.length > 0 && post.length > 0) ? pre ~ " " ~ post
                    : (pre.length > 0 ? pre : post);
        base = stripYencKeyword(base).strip;
        // Strip outer quotes.
        if (base.length >= 2 && base[0] == '"' && base[$-1] == '"')
            base = base[1 .. $-1].strip;
        if (base.length == 0)
            base = h.subject;   // fall back to raw subject

        string key = base.toLower ~ "\x00" ~ normalizePoster(h.from);

        if (key !in groupMap)
        {
            BinaryGroup g;
            g.baseName    = base;
            g.poster      = h.from;
            g.date        = h.date;
            g.totalParts  = totalParts;
            groupMap[key] = g;
        }

        BinaryGroup* g = key in groupMap;
        // Keep the smallest totalParts seen (subject lines sometimes disagree).
        if (totalParts > g.totalParts)
            g.totalParts = totalParts;
        if (h.number < g.firstArticleNum)
            g.firstArticleNum = h.number;

        g.parts ~= PartEntry(partNum, h.messageId, h.bytes, h.number);
    }

    // -----------------------------------------------------------------------
    // Convert groups → BinaryPost → ThreadItem.
    // -----------------------------------------------------------------------
    ThreadItem[] binaryItems;

    foreach (ref g; groupMap)
    {
        // Sort parts by part number.
        g.parts.sort!((a, b) => a.partNum < b.partNum);

        BinaryPost bp;
        bp.baseName        = g.baseName;
        bp.poster          = g.poster;
        bp.date            = g.date;
        bp.totalParts      = g.totalParts;
        bp.presentParts    = cast(uint) g.parts.length;
        bp.isComplete      = (bp.presentParts == bp.totalParts);
        bp.firstArticleNum = g.firstArticleNum;
        bp.messageIds.length = bp.totalParts;

        foreach (ref pe; g.parts)
        {
            bp.totalBytes += pe.bytes;
            if (pe.partNum >= 1 && pe.partNum <= bp.totalParts)
                bp.messageIds[pe.partNum - 1] = pe.messageId;
        }

        string ln    = bp.baseName.toLower;
        bp.hasNfo    = ln.indexOf(".nfo") >= 0;
        bp.hasPar2   = ln.indexOf(".par2") >= 0;

        binaryItems ~= ThreadItem(ItemKind.Binary, Header.init, bp);
    }

    // Sort binary items by firstArticleNum so they interleave properly.
    binaryItems.sort!((a, b) => a.binary.firstArticleNum < b.binary.firstArticleNum);

    // -----------------------------------------------------------------------
    // Merge text and binary items by article number.
    // -----------------------------------------------------------------------
    auto result = appender!(ThreadItem[])();
    result.reserve(textItems.length + binaryItems.length);

    size_t ti = 0, bi = 0;
    while (ti < textItems.length && bi < binaryItems.length)
    {
        long tn = textItems[ti].header.number;
        long bn = binaryItems[bi].binary.firstArticleNum;
        if (tn <= bn)
            result ~= textItems[ti++];
        else
            result ~= binaryItems[bi++];
    }
    while (ti < textItems.length)  result ~= textItems[ti++];
    while (bi < binaryItems.length) result ~= binaryItems[bi++];

    return result.data;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private string stripYencKeyword(string s)
{
    // Remove "yEnc" (case-insensitive) from the string.
    import std.uni : toLower;
    string sl = s.toLower;
    auto pos = sl.indexOf("yenc");
    if (pos < 0) return s;
    return (s[0 .. pos] ~ s[pos + 4 .. $]).strip;
}

private string normalizePoster(string from)
{
    // Use the email address inside <> if present, else the whole field.
    auto lt = from.indexOf('<');
    auto gt = from.indexOf('>');
    if (lt >= 0 && gt > lt)
        return from[lt + 1 .. gt].toLower;
    return from.strip.toLower;
}
