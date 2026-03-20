module cache.headerdb;

import std.file   : exists, read, write, append, mkdirRecurse, remove;
import std.path   : buildPath, dirName;
import std.string : fromStringz;
import std.stdio  : File;

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
// Cache management
// ---------------------------------------------------------------------------

/// Delete the cache and index files so the next sync starts from scratch.
void clearCache(string cpath, string ipath)
{
    if (exists(cpath)) remove(cpath);
    if (exists(ipath)) remove(ipath);
}

// ---------------------------------------------------------------------------
// Streaming appender — writes CacheRecords directly from raw XOVER lines.
// No Header[] or ubyte[] buf is ever allocated; one CacheRecord lives on the
// stack per line and is written immediately to the open file.
// ---------------------------------------------------------------------------

struct CacheAppender
{
private:
    File   _file;
    string _ipath;
    long   _maxNum;
    long   _prevCount;
    long   _count;

public:
    /// Open cpath for streaming append.  Reads existing index so count/watermark
    /// are carried forward.  Call close() when done to flush the index.
    static CacheAppender open(string cpath, string ipath)
    {
        mkdirRecurse(dirName(cpath));
        auto idx = readIndex(ipath);
        CacheAppender a;
        a._ipath     = ipath;
        a._maxNum    = idx.watermark;
        a._prevCount = idx.count;
        a._count     = 0;
        a._file      = File(cpath, "ab");
        return a;
    }

    /// Current write position (bytes from start of file).
    /// Save before a batch; pass to truncateToPos() to roll back on retry.
    ulong filePos()
    {
        _file.flush();
        return _file.tell();
    }

    /// Truncate the file back to pos and re-seek there.
    /// Call this before retrying a batch that partially wrote records.
    void truncateToPos(ulong pos)
    {
        import core.stdc.stdio  : fileno;
        import core.sys.posix.unistd : ftruncate;
        _file.flush();
        ftruncate(fileno(_file.getFP()), cast(long) pos);
        _file.seek(pos);
    }

    /// Parse one raw XOVER tab-separated line and write it as a CacheRecord.
    /// Allocates only the temporary strings needed for subject/from decoding;
    /// those are freed after this call returns.
    void putLine(string line)
    {
        import std.string : split;
        import std.conv   : to, ConvException;

        if (line.length == 0) return;
        auto fields = line.split('\t');
        if (fields.length == 0) return;

        CacheRecord rec;

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

        rec.number = safeLong(0);
        if (rec.number > _maxNum) _maxNum = rec.number;
        rec.bytes = cast(ulong) safeLong(6);
        rec.lines = safeUint(7);

        if (fields.length > 1) copyStr(rec.subject[], sanitizeUtf8(decodeRfc2047(fields[1])));
        if (fields.length > 2) copyStr(rec.from[],    sanitizeUtf8(decodeRfc2047(fields[2])));
        if (fields.length > 3) copyStr(rec.date[],    fields[3]);
        if (fields.length > 4) copyStr(rec.msgid[],   fields[4]);

        _file.rawWrite((cast(ubyte*) &rec)[0 .. CacheRecord.sizeof]);
        _count++;
    }

    /// Flush and close the file, then write the updated index.
    void close()
    {
        _file.close();
        CacheIndex idx;
        idx.watermark = _maxNum;
        idx.count     = _prevCount + _count;
        writeIndex(_ipath, idx);
    }
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
