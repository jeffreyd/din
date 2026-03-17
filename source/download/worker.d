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
    foreach (chunk; chunks)
        if (chunk.length > 0)
            f.rawWrite(chunk);
    f.close();

    job.decodedFiles ~= outPath;
    job.state = JobState.Done;
    if (onProgress) onProgress();
}

private string sanitizeFname(string name)
{
    string s = name;
    if (s.length >= 2 && s[0] == '"' && s[$-1] == '"')
        s = s[1 .. $-1];

    import std.string : strip;
    s = s.strip;

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
