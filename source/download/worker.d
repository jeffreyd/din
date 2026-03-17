module download.worker;

import std.file  : mkdirRecurse;
import std.path  : buildPath;
import std.array : appender;
import std.conv  : to;

import nntp.pool      : NntpPool;
import binary.yenc    : decodeYenc;
import download.queue : DownloadJob, JobState;

/// Download and yEnc-decode all segments sequentially.
/// onProgress is called after each segment so the display can refresh.
void runJob(ref DownloadJob job, NntpPool pool,
            void delegate() onProgress = null)
{
    job.state = JobState.Downloading;

    string[] msgIds    = job.post.messageIds;
    int      totalSegs = cast(int) msgIds.length;

    uint actualSegs = 0;
    foreach (id; msgIds) if (id.length > 0) actualSegs++;

    job.progress.start(actualSegs, job.post.totalBytes);

    mkdirRecurse(job.destDir);

    ubyte[][] chunks;
    chunks.length = totalSegs;

    foreach (idx, msgId; msgIds)
    {
        if (msgId.length == 0) continue;

        try
        {
            string body = pool.fetchBody(msgId);
            auto   res  = decodeYenc(body);
            chunks[idx] = res.data;
            job.progress.segmentDone(res.data.length);
            if (onProgress) onProgress();
        }
        catch (Exception e)
        {
            job.state = JobState.Failed;
            job.error = "Part " ~ (idx + 1).to!string ~ ": " ~ e.msg;
            return;
        }
    }

    job.state = JobState.Decoding;
    if (onProgress) onProgress();

    string fname   = sanitizeFname(job.post.baseName);
    string outPath = buildPath(job.destDir, fname);

    import std.stdio : File;
    auto f = File(outPath, "wb");
    // Write chunks in order.  Missing parts (empty chunk) are zero-padded so
    // subsequent parts land at the correct file offset.
    foreach (i, chunk; chunks)
    {
        if (chunk.length > 0)
        {
            f.rawWrite(chunk);
        }
        else if (job.post.messageIds[i].length > 0)
        {
            // Part was present in the index but failed to download — pad with zeros.
            // We don't know the exact size, so use the average segment size.
            ulong avgSize = job.post.totalBytes > 0 && job.post.totalParts > 0
                          ? job.post.totalBytes / job.post.totalParts
                          : 768_000;   // ~750 KB fallback
            ubyte[] pad = new ubyte[](cast(size_t) avgSize);
            f.rawWrite(pad);
        }
        // Empty msgId (truly missing part) — skip entirely, nothing we can do.
    }
    f.close();

    job.decodedFiles ~= outPath;
    job.state = JobState.Done;
    if (onProgress) onProgress();
}

private string sanitizeFname(string name)
{
    import std.string : strip, lastIndexOf, indexOf;

    // Prefer the last "quoted.ext" string in the subject — that's almost
    // always the actual filename (e.g. 'Some Title - "file.mp3"').
    string s = extractQuotedFilename(name);
    if (s.length == 0)
    {
        // Fall back to the full baseName, stripping outer quotes.
        s = name;
        if (s.length >= 2 && s[0] == '"' && s[$-1] == '"')
            s = s[1 .. $-1];
        s = s.strip;
    }

    auto app = appender!string;
    foreach (dchar c; s)
    {
        if (c == '/' || c == '\\' || c == '\0')
            app ~= '-';
        else
            app ~= c;
    }

    string result = app.data.strip;
    if (result.length > 0 && result[0] == '.')
        result = "_" ~ result[1 .. $];
    return result.length > 0 ? result : "download";
}

/// Find the last "quoted string" in s that looks like a filename (has a dot,
/// no path separators).  Returns "" if nothing suitable is found.
private string extractQuotedFilename(string name)
{
    import std.string : lastIndexOf, indexOf;

    long e = lastIndexOf(name, '"');
    if (e <= 0) return "";
    long b = lastIndexOf(name[0 .. cast(size_t) e], '"');
    if (b < 0) return "";

    string candidate = name[cast(size_t)(b + 1) .. cast(size_t) e];
    if (candidate.length == 0)                   return "";
    if (indexOf(candidate, '.') < 0)             return "";  // no extension
    if (indexOf(candidate, '/') >= 0)            return "";  // path separator
    if (indexOf(candidate, '\\') >= 0)           return "";
    return candidate;
}
