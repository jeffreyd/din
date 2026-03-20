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

/// Thrown when the server returns an unexpected response code (e.g. 430).
/// withRetry does NOT reconnect for these — the connection is still valid.
class NntpResponseException : NntpException
{
    int code;
    this(string msg, int code, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        this.code = code;
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
    if (fields.length > 1) h.subject    = sanitizeUtf8(decodeRfc2047(fields[1])).idup;
    if (fields.length > 2) h.from       = sanitizeUtf8(decodeRfc2047(fields[2])).idup;
    if (fields.length > 3) h.date       = fields[3].idup;
    if (fields.length > 4) h.messageId  = fields[4].idup;
    if (fields.length > 5) h.references = fields[5].idup;
    if (fields.length > 6) h.bytes      = cast(ulong) safeLong(6);
    if (fields.length > 7) h.lines      = safeUint(7);

    return h;
}

/// Decode RFC 2047 encoded words in a header string.
/// Handles Q-encoding (quoted-printable) and B-encoding (base64).
/// Adjacent encoded words separated only by whitespace are concatenated
/// without the intervening whitespace (RFC 2047 §6.2).
string decodeRfc2047(string s)
{
    import std.string : indexOf;
    import std.array  : appender;

    if (s.indexOf("=?") < 0) return s;  // fast path: nothing to decode

    auto   result     = appender!string;
    size_t i          = 0;
    bool   lastWasEnc = false;
    string pendingSpc;

    while (i < s.length)
    {
        if (i + 1 < s.length && s[i] == '=' && s[i+1] == '?')
        {
            size_t advance;
            string decoded = tryDecodeWord(s, i, advance);
            if (advance > 0)
            {
                if (!lastWasEnc) result ~= pendingSpc;
                pendingSpc  = "";
                result     ~= decoded;
                lastWasEnc  = true;
                i          += advance;
                continue;
            }
        }

        if (s[i] == ' ' || s[i] == '\t')
        {
            pendingSpc ~= s[i++];
        }
        else
        {
            result    ~= pendingSpc;
            pendingSpc = "";
            result    ~= s[i++];
            lastWasEnc = false;
        }
    }
    result ~= pendingSpc;
    return result.data;
}

// Try to parse and decode one encoded word beginning at s[pos].
// On success: returns the decoded string and sets advance to bytes consumed.
// On failure: returns "" and sets advance = 0.
private string tryDecodeWord(string s, size_t pos, out size_t advance)
{
    advance = 0;
    size_t i = pos;

    if (i + 1 >= s.length || s[i] != '=' || s[i+1] != '?') return "";
    i += 2;

    // charset — everything up to the next '?'
    size_t csStart = i;
    while (i < s.length && s[i] != '?') i++;
    if (i >= s.length) return "";
    string charset = s[csStart .. i];
    i++;  // skip '?'

    // encoding character ('Q' or 'B') followed immediately by '?'
    if (i + 1 >= s.length || s[i+1] != '?') return "";
    char enc = s[i];
    i += 2;  // skip enc + '?'

    // encoded text — everything up to the closing '?='
    size_t txtStart = i;
    while (i + 1 < s.length && !(s[i] == '?' && s[i+1] == '=')) i++;
    if (i + 1 >= s.length || s[i] != '?' || s[i+1] != '=') return "";
    string text = s[txtStart .. i];
    i += 2;  // skip '?='

    advance = i - pos;
    return rfc2047DecodeWord(charset, enc, text);
}

private string rfc2047DecodeWord(string charset, char enc, string text)
{
    ubyte[] bytes;
    if (enc == 'Q' || enc == 'q')
        bytes = decodeQBytes(text);
    else if (enc == 'B' || enc == 'b')
        bytes = decodeBase64Bytes(text);
    else
        return text;
    return rfc2047BytesToUtf8(bytes, charset);
}

// Q-encoding: '=' followed by two hex digits, '_' = space, rest literal.
private ubyte[] decodeQBytes(string s)
{
    import std.array : appender;
    auto app = appender!(ubyte[])();
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '_')
        {
            app ~= cast(ubyte) 0x20;
            i++;
        }
        else if (s[i] == '=' && i + 2 < s.length)
        {
            ubyte hi = hexNibble(s[i+1]);
            ubyte lo = hexNibble(s[i+2]);
            if (hi != 0xFF && lo != 0xFF)
            {
                app ~= cast(ubyte)((hi << 4) | lo);
                i += 3;
            }
            else
            {
                app ~= cast(ubyte) s[i++];
            }
        }
        else
        {
            app ~= cast(ubyte) s[i++];
        }
    }
    return app.data;
}

private ubyte hexNibble(char c)
{
    if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
    if (c >= 'A' && c <= 'F') return cast(ubyte)(c - 'A' + 10);
    if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
    return 0xFF;
}

private ubyte[] decodeBase64Bytes(string s)
{
    import std.base64 : Base64;
    try   return Base64.decode(s).dup;
    catch (Exception) return cast(ubyte[]) s.dup;
}

// Convert a decoded byte array to a UTF-8 string given the source charset.
private string rfc2047BytesToUtf8(ubyte[] bytes, string charset)
{
    import std.string : toLower, strip;
    import std.array  : appender;

    string cs = charset.toLower.strip;

    if (cs == "us-ascii" || cs == "utf-8" || cs == "utf8" || cs == "")
        return sanitizeUtf8(cast(string) bytes);

    // Latin-1 / Windows-1252: each byte maps directly to its Unicode code point.
    if (cs == "iso-8859-1" || cs == "latin-1"  || cs == "latin1" ||
        cs == "iso8859-1"  || cs == "windows-1252" || cs == "cp1252")
    {
        auto app = appender!string;
        foreach (b; bytes)
        {
            if (b < 0x80)
                app ~= cast(char) b;
            else
            {
                app ~= cast(char)(0xC0 | (b >> 6));
                app ~= cast(char)(0x80 | (b & 0x3F));
            }
        }
        return app.data;
    }

    // Unknown charset: best-effort UTF-8.
    return sanitizeUtf8(cast(string) bytes);
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
