module binary.yenc;

import std.exception : enforce;
import std.string    : startsWith, indexOf;
import std.array     : split;
import std.conv      : to, ConvException;

struct YencInfo
{
    string name;
    ulong  size;
    uint   part;    // 0 for single-part
    uint   total;   // 0 for single-part
    ulong  begin;   // byte offset (1-based) for this part
    ulong  end;
}

struct YencResult
{
    YencInfo info;
    ubyte[]  data;
    uint     crc32;    // from =yend crc32= / pcrc32= (0 if absent)
    bool     crcValid; // false if crc32 present and didn't match
}

/// Decode a yEnc-encoded NNTP body.
/// Throws on missing =ybegin / =yend markers.
YencResult decodeYenc(string body)
{
    auto lines = body.split('\n');
    int  i     = 0;

    // Skip to =ybegin.
    while (i < cast(int) lines.length && !lines[i].startsWith("=ybegin"))
        i++;
    enforce(i < cast(int) lines.length, "yEnc: no =ybegin found");

    YencResult res;
    res.info = parseYbegin(lines[i++]);

    if (i < cast(int) lines.length && lines[i].startsWith("=ypart"))
        parseYpart(lines[i++], res.info);

    // Decode body lines until =yend.
    // Reserve ~body.length bytes upfront to avoid repeated reallocations.
    ubyte[] decoded;
    decoded.reserve(body.length);
    while (i < cast(int) lines.length && !lines[i].startsWith("=yend"))
    {
        decodeYencLine(cast(const(ubyte)[]) lines[i], decoded);
        i++;
    }
    enforce(i < cast(int) lines.length, "yEnc: no =yend found");

    uint crcFromPost = extractCrc(lines[i]);
    res.data = decoded;
    if (crcFromPost != 0)
    {
        res.crc32    = crcFromPost;
        res.crcValid = (computeCrc32(decoded) == crcFromPost);
    }
    else
    {
        res.crcValid = true;  // no CRC to check
    }

    return res;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

YencInfo parseYbegin(string line)
{
    YencInfo h;
    h.name  = tagValue(line, "name", true);
    string s = tagValue(line, "size");  if (s.length) h.size  = safeToUlong(s);
    string p = tagValue(line, "part");  if (p.length) h.part  = safeToUint(p);
    string t = tagValue(line, "total"); if (t.length) h.total = safeToUint(t);
    return h;
}

void parseYpart(string line, ref YencInfo h)
{
    string b = tagValue(line, "begin"); if (b.length) h.begin = safeToUlong(b);
    string e = tagValue(line, "end");   if (e.length) h.end   = safeToUlong(e);
}

uint extractCrc(string line)
{
    // Prefer pcrc32 (part CRC), fall back to crc32.
    string v = tagValue(line, "pcrc32");
    if (!v.length) v = tagValue(line, "crc32");
    if (!v.length) return 0;
    try
    {
        auto tmp = v;
        return to!uint(tmp, 16);
    }
    catch (Exception) return 0;
}

/// Extract value of key=value from a yEnc header line.
/// Set toEndOfLine=true for the name= field, which extends to end of line
/// and may contain spaces (unlike all other yEnc header fields).
string tagValue(string line, string key, bool toEndOfLine = false)
{
    string needle = key ~ "=";
    auto   pos    = line.indexOf(needle);
    if (pos < 0) return "";
    string rest = line[pos + needle.length .. $];
    if (!rest.length) return "";
    if (rest[0] == '"')
    {
        rest = rest[1 .. $];
        auto end = rest.indexOf('"');
        return end >= 0 ? rest[0 .. end] : rest;
    }
    if (toEndOfLine)
    {
        // Strip trailing whitespace / carriage return.
        size_t end = rest.length;
        while (end > 0 && (rest[end - 1] == '\r' || rest[end - 1] == ' ' || rest[end - 1] == '\t'))
            end--;
        return rest[0 .. end];
    }
    size_t end = 0;
    while (end < rest.length && rest[end] != ' ' && rest[end] != '\t')
        end++;
    return rest[0 .. end];
}

void decodeYencLine(const(ubyte)[] line, ref ubyte[] out_)
{
    // Pre-extend by the line length (decoded output <= encoded length).
    // We'll trim to the actual count written at the end.
    size_t base = out_.length;
    out_.length = base + line.length;

    size_t outIdx = base;
    size_t i      = 0;
    while (i < line.length)
    {
        ubyte b = line[i++];
        if (b == '=')
        {
            if (i >= line.length) break;
            // Escaped: subtract 42 + 64 (= 106) mod 256.
            b = cast(ubyte)(line[i++] - 106);
        }
        else
        {
            b = cast(ubyte)(b - 42);
        }
        out_[outIdx++] = b;
    }
    out_.length = outIdx;   // trim to bytes actually written
}

/// CRC-32 with reflected polynomial 0xEDB88320 (zip/zlib compatible).
uint computeCrc32(const(ubyte)[] data)
{
    static uint[256] table;
    static bool      ready;
    if (!ready)
    {
        foreach (idx; 0 .. 256)
        {
            uint c = cast(uint) idx;
            foreach (j; 0 .. 8)
                c = (c & 1) ? (0xEDB8_8320u ^ (c >> 1)) : (c >> 1);
            table[idx] = c;
        }
        ready = true;
    }
    uint crc = 0xFFFF_FFFFu;
    foreach (b; data)
        crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFF_FFFFu;
}

ulong safeToUlong(string s)
{
    try return s.to!ulong;
    catch (ConvException) return 0;
}

uint safeToUint(string s)
{
    try return s.to!uint;
    catch (ConvException) return 0;
}
