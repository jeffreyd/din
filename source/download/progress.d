module download.progress;

import std.datetime.stopwatch : StopWatch, AutoStart;

struct SegmentProgress
{
    uint   segsDone;
    uint   segsError;
    uint   segsTotal;
    ulong  bytesDone;
    ulong  bytesTotal;
    double bytesPerSec;  // current average
    double etaSecs;      // estimated seconds remaining (0 if unknown)
}

/// Tracks progress for a single download job.
struct ProgressTracker
{
private:
    StopWatch _sw;
    uint      _segsDone;
    uint      _segsError;
    uint      _segsTotal;
    ulong     _bytesDone;
    ulong     _bytesTotal;

public:
    void start(uint segsTotal, ulong bytesTotal)
    {
        _segsTotal  = segsTotal;
        _bytesTotal = bytesTotal;
        _segsDone   = 0;
        _segsError  = 0;
        _bytesDone  = 0;
        _sw         = StopWatch(AutoStart.yes);
    }

    void segmentDone(ulong bytes)
    {
        _segsDone++;
        _bytesDone += bytes;
    }

    void segmentError()
    {
        _segsError++;
    }

    /// Update counters from atomic values read by the main thread.
    void update(uint segs, ulong bytes)
    {
        _segsDone  = segs;
        _bytesDone = bytes;
    }

    SegmentProgress snapshot() const
    {
        SegmentProgress p;
        p.segsDone   = _segsDone;
        p.segsError  = _segsError;
        p.segsTotal  = _segsTotal;
        p.bytesDone  = _bytesDone;
        p.bytesTotal = _bytesTotal;

        double elapsedMs = cast(double) _sw.peek.total!"msecs";
        if (elapsedMs > 0)
            p.bytesPerSec = _bytesDone / (elapsedMs / 1000.0);

        if (p.bytesPerSec > 0 && _bytesTotal > _bytesDone)
            p.etaSecs = cast(double)(_bytesTotal - _bytesDone) / p.bytesPerSec;

        return p;
    }
}
