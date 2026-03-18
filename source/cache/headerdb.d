module cache.headerdb;

import std.file   : exists, read, write, append, mkdirRecurse;
import std.path   : buildPath, dirName;
import std.string : fromStringz;

import nntp.commands : sanitizeUtf8, decodeRfc2047;

import model.header : Header;

// ---------------------------------------------------------------------------
// On-disk layout (packed, no padding)
// ---------------------------------------------------------------------------

align(1) struct CacheRecord
{
    long      number;        //   8
    ulong     bytes;         //   8
    uint      lines;         //   4
    char[128] msgid;         // 128
    char[64]  from;          //  64
    char[64]  date;          //  64
    char[256] subject;       // 256
                             // 532 bytes total
}

align(1) struct CacheIndex
{
    long watermark;   // highest article number stored
    long count;       // number of records
}

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

string cachePath(string cacheDir, string serverName, string groupName)
{
    return buildPath(cacheDir, serverName, groupName ~ ".cache");
}

string indexPath(string cacheDir, string serverName, string groupName)
{
    return buildPath(cacheDir, serverName, groupName ~ ".idx");
}

// ---------------------------------------------------------------------------
// Index I/O
// ---------------------------------------------------------------------------

CacheIndex readIndex(string idxPath)
{
    if (!exists(idxPath)) return CacheIndex.init;
    auto data = cast(ubyte[]) read(idxPath);
    if (data.length < CacheIndex.sizeof) return CacheIndex.init;
    return *(cast(CacheIndex*) data.ptr);
}

private void writeIndex(string idxPath, CacheIndex idx)
{
    mkdirRecurse(dirName(idxPath));
    write(idxPath, (cast(ubyte*) &idx)[0 .. CacheIndex.sizeof]);
}

// ---------------------------------------------------------------------------
// Header I/O
// ---------------------------------------------------------------------------

Header[] loadHeaders(string cpath)
{
    if (!exists(cpath)) return [];
    auto   data = cast(ubyte[]) read(cpath);
    size_t n    = data.length / CacheRecord.sizeof;
    Header[] h;
    h.reserve(n);
    for (size_t i = 0; i < n; i++)
    {
        auto rec = *(cast(CacheRecord*) (data.ptr + i * CacheRecord.sizeof));
        h ~= Header(
            rec.number,
            sanitizeUtf8(decodeRfc2047(fromStringz(rec.subject.ptr).idup)),
            sanitizeUtf8(decodeRfc2047(fromStringz(rec.from.ptr).idup)),
            fromStringz(rec.date.ptr).idup,
            fromStringz(rec.msgid.ptr).idup,
            "",            // references not cached (not needed until Phase 4 threading)
            rec.bytes,
            rec.lines);
    }
    return h;
}

void appendHeaders(string cpath, string ipath, Header[] headers)
{
    if (headers.length == 0) return;

    mkdirRecurse(dirName(cpath));

    auto idx    = readIndex(ipath);
    long maxNum = idx.watermark;

    ubyte[] buf;
    buf.reserve(headers.length * CacheRecord.sizeof);

    foreach (ref h; headers)
    {
        if (h.number > maxNum) maxNum = h.number;

        CacheRecord rec;
        rec.number = h.number;
        rec.bytes  = h.bytes;
        rec.lines  = h.lines;
        copyStr(rec.msgid[],   h.messageId);
        copyStr(rec.from[],    h.from);
        copyStr(rec.date[],    h.date);
        copyStr(rec.subject[], h.subject);

        buf ~= (cast(ubyte*) &rec)[0 .. CacheRecord.sizeof];
    }

    append(cpath, cast(void[]) buf);

    idx.watermark  = maxNum;
    idx.count     += cast(long) headers.length;
    writeIndex(ipath, idx);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private void copyStr(char[] dest, string src)
{
    dest[] = '\0';
    size_t n = src.length < dest.length - 1 ? src.length : dest.length - 1;
    dest[0 .. n] = src[0 .. n];
}
