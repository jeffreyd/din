module download.worker;

import std.file  : mkdirRecurse;
import std.path  : buildPath;
import std.array : appender;
import std.conv  : to;
import std.stdio : File;

import nntp.pool      : NntpPool;
import binary.yenc    : decodeYenc;
import download.queue : DownloadJob, JobState;

/// Download and yEnc-decode all segments in parallel using the connection pool.
/// Each segment is written directly to its correct byte offset (from =ypart
/// begin=/end=) so missing or out-of-order segments never corrupt the file.
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

    // Output file — opened on first successful decode so we have the
    // yEnc name= and total size before creating anything on disk.
    File   outFile;
    bool   fileOpened = false;
    string outPath;
    string yencName;

    pool.fetchBodies(msgIds,
        delegate void(size_t idx, string body)
        {
            try
            {
                auto res = decodeYenc(body);

                // Open (and pre-allocate) the output file on first success.
                if (!fileOpened)
                {
                    if (res.info.name.length > 0)
                        yencName = res.info.name;
                    string fname = sanitizeFname(
                        yencName.length > 0 ? yencName : job.post.baseName);
                    outPath   = buildPath(job.destDir, fname);
                    outFile   = File(outPath, "wb");
                    fileOpened = true;

                    // Pre-allocate to the full file size so that holes left by
                    // any missing segments are zero-filled rather than absent.
                    if (res.info.size > 0)
                    {
                        outFile.seek(cast(long)(res.info.size) - 1);
                        ubyte zero = 0;
                        outFile.rawWrite((&zero)[0 .. 1]);
                    }
                }

                // Seek to the segment's correct byte offset.
                // =ypart begin= is 1-based; 0 means no =ypart (single-part
                // file), so write from the start.
                outFile.seek(res.info.begin > 0
                    ? cast(long)(res.info.begin) - 1
                    : 0);

                outFile.rawWrite(res.data);

                if (yencName.length == 0 && res.info.name.length > 0)
                    yencName = res.info.name;

                job.progress.segmentDone(res.data.length);
            }
            catch (Exception e)
            {
                job.progress.segmentError();
                job.error = "Part " ~ (idx + 1).to!string ~ ": " ~ e.msg;
            }
            if (onProgress) onProgress();
        },
        delegate void(size_t idx, string msg)
        {
            job.progress.segmentError();
            job.error = "Part " ~ (idx + 1).to!string ~ ": " ~ msg;
            if (onProgress) onProgress();
        }
    );

    if (fileOpened)
    {
        outFile.close();
        job.decodedFiles ~= outPath;
    }

    job.state = JobState.Done;
    if (onProgress) onProgress();
}

private string sanitizeFname(string name)
{
    import std.string : strip, lastIndexOf, indexOf;

    string s = extractQuotedFilename(name);
    if (s.length == 0)
    {
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

private string extractQuotedFilename(string name)
{
    import std.string : lastIndexOf, indexOf;

    long e = lastIndexOf(name, '"');
    if (e <= 0) return "";
    long b = lastIndexOf(name[0 .. cast(size_t) e], '"');
    if (b < 0) return "";

    string candidate = name[cast(size_t)(b + 1) .. cast(size_t) e];
    if (candidate.length == 0)                   return "";
    if (indexOf(candidate, '.') < 0)             return "";
    if (indexOf(candidate, '/') >= 0)            return "";
    if (indexOf(candidate, '\\') >= 0)           return "";
    return candidate;
}
