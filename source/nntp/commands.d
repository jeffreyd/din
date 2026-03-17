module nntp.commands;

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

class NntpException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

class NntpAuthException : NntpException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

// ---------------------------------------------------------------------------
// Response
// ---------------------------------------------------------------------------

struct NntpResponse
{
    int    code;
    string message;
}

/// Parse the first line of any NNTP server response.
NntpResponse parseResponse(string line)
{
    import std.conv      : to, ConvException;
    import std.exception : enforce;

    enforce(line.length >= 3, "NNTP response too short: " ~ line);

    NntpResponse r;
    try
        r.code = line[0 .. 3].to!int;
    catch (ConvException e)
        throw new NntpException("Malformed response code: " ~ line);

    r.message = line.length > 4 ? line[4 .. $] : "";
    return r;
}

// ---------------------------------------------------------------------------
// GROUP response
// ---------------------------------------------------------------------------

struct GroupInfo
{
    long   count;
    long   first;
    long   last;
    string name;
}

/// Parse the payload of a 211 response: "count first last name"
GroupInfo parseGroupInfo(string message, string requestedName)
{
    import std.string : split;
    import std.conv   : to, ConvException;

    auto parts = message.split(' ');
    GroupInfo g;
    g.name = requestedName;

    long safeInt(size_t i)
    {
        if (i >= parts.length || parts[i].length == 0) return 0;
        try return parts[i].to!long;
        catch (ConvException) return 0;
    }

    g.count = safeInt(0);
    g.first = safeInt(1);
    g.last  = safeInt(2);
    if (parts.length > 3 && parts[3].length > 0)
        g.name = parts[3];

    return g;
}

// ---------------------------------------------------------------------------
// XOVER response
// ---------------------------------------------------------------------------

import model.header : Header;

/// Parse one tab-separated line from an XOVER response into a Header.
Header parseXoverLine(string line)
{
    import std.string : split;
    import std.conv   : to, ConvException;

    auto fields = line.split('\t');
    Header h;

    long safeLong(size_t i)
    {
        if (i >= fields.length) return 0;
        try return fields[i].to!long;
        catch (ConvException) return 0;
    }

    uint safeUint(size_t i)
    {
        if (i >= fields.length) return 0;
        try return fields[i].to!uint;
        catch (ConvException) return 0;
    }

    if (fields.length > 0) h.number     = safeLong(0);
    if (fields.length > 1) h.subject    = sanitizeUtf8(fields[1]);
    if (fields.length > 2) h.from       = sanitizeUtf8(fields[2]);
    if (fields.length > 3) h.date       = fields[3];
    if (fields.length > 4) h.messageId  = fields[4];
    if (fields.length > 5) h.references = fields[5];
    if (fields.length > 6) h.bytes      = cast(ulong) safeLong(6);
    if (fields.length > 7) h.lines      = safeUint(7);

    return h;
}

// Replace invalid UTF-8 byte sequences with '?'.
// Usenet headers are often Latin-1; this prevents crashes in format/ncurses.
string sanitizeUtf8(string s)
{
    import std.utf   : decode, UTFException, validate;
    import std.array : appender;

    // Fast path: already valid.
    try { validate(s); return s; } catch (UTFException) {}

    auto app = appender!string;
    size_t i = 0;
    while (i < s.length)
    {
        try
        {
            size_t j = i;
            decode(s, j);
            app ~= s[i .. j];
            i = j;
        }
        catch (UTFException)
        {
            app ~= '?';
            ++i;
        }
    }
    return app.data;
}
