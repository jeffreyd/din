module binary.nzb;

import std.conv      : to, ConvException;
import std.string    : strip, toLower, indexOf, splitLines, join, startsWith;
import std.algorithm : sort, filter;
import std.array     : array;
import dxml.dom;

import model.binary : BinaryPost;

/// Parse NZB 1.1 XML and return one BinaryPost per <file> element.
/// Throws XMLParsingException on malformed XML.
BinaryPost[] parseNzb(string xmlText)
{
    // dxml does not handle DOCTYPE declarations — strip them before parsing.
    string cleaned = xmlText.splitLines
        .filter!(l => !l.strip.startsWith("<!DOCTYPE"))
        .array
        .join("\n");

    // parseDOM returns the root element (e.g. <nzb>).
    auto root = parseDOM(cleaned);

    BinaryPost[] result;

    foreach (fileNode; root.children)
    {
        if (fileNode.type != EntityType.elementStart) continue;
        if (fileNode.name != "file") continue;

        string poster, subject, dateStr;
        foreach (attr; fileNode.attributes)
        {
            switch (attr.name)
            {
                case "poster":  poster  = attr.value; break;
                case "subject": subject = attr.value; break;
                case "date":    dateStr = attr.value; break;
                default: break;
            }
        }

        if (subject.length == 0) continue;

        struct Seg { uint number; ulong bytes; string msgId; }
        Seg[] segs;

        foreach (child; fileNode.children)
        {
            if (child.type != EntityType.elementStart) continue;
            if (child.name != "segments") continue;

            foreach (segNode; child.children)
            {
                if (segNode.type != EntityType.elementStart) continue;
                if (segNode.name != "segment") continue;

                Seg s;
                foreach (attr; segNode.attributes)
                {
                    switch (attr.name)
                    {
                        case "number":
                            try { s.number = attr.value.to!uint; }
                            catch (ConvException) {}
                            break;
                        case "bytes":
                            try { s.bytes = attr.value.to!ulong; }
                            catch (ConvException) {}
                            break;
                        default: break;
                    }
                }

                // Message-ID is the text content of <segment>.
                foreach (textNode; segNode.children)
                {
                    if (textNode.type == EntityType.text)
                        s.msgId = textNode.text.strip;
                }

                // Ensure message-ID is wrapped in angle brackets.
                if (s.msgId.length > 0 && s.msgId[0] != '<')
                    s.msgId = "<" ~ s.msgId ~ ">";

                if (s.number > 0 && s.msgId.length > 2)
                    segs ~= s;
            }
        }

        if (segs.length == 0) continue;

        segs.sort!((a, b) => a.number < b.number);
        uint maxPart = segs[$-1].number;

        BinaryPost bp;
        bp.baseName          = stripNzbSubject(subject);
        bp.poster            = poster;
        bp.date              = dateStr;
        bp.totalParts        = maxPart;
        bp.presentParts      = cast(uint) segs.length;
        bp.isComplete        = (bp.presentParts == bp.totalParts);
        bp.messageIds.length = maxPart;

        foreach (ref s; segs)
        {
            bp.totalBytes += s.bytes;
            if (s.number >= 1 && s.number <= maxPart)
                bp.messageIds[s.number - 1] = s.msgId;
        }

        string ln  = bp.baseName.toLower;
        bp.hasNfo  = ln.indexOf(".nfo") >= 0;
        bp.hasPar2 = ln.indexOf(".par2") >= 0;

        result ~= bp;
    }

    return result;
}

/// Strip part markers and "yEnc" from an NZB subject to produce a clean filename.
private string stripNzbSubject(string subject)
{
    import std.regex : regex, replaceAll;

    static auto partRe = regex(`\s*[\[\(]\d{1,4}\s*/\s*\d{1,4}[\]\)]\s*`);
    string s = subject.replaceAll(partRe, " ").strip;

    // Remove "yEnc" (case-insensitive).
    string sl = s.toLower;
    auto pos = sl.indexOf("yenc");
    if (pos >= 0)
        s = (s[0 .. pos] ~ s[pos + 4 .. $]).strip;

    // Strip outer double-quotes.
    if (s.length >= 2 && s[0] == '"' && s[$-1] == '"')
        s = s[1 .. $-1].strip;

    return s.length > 0 ? s : subject;
}
