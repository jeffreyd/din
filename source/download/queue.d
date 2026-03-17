module download.queue;

import model.binary      : BinaryPost;
import download.progress : ProgressTracker;

enum JobState
{
    Queued,
    Downloading,
    Decoding,
    Done,
    Failed,
}

struct DownloadJob
{
    BinaryPost      post;
    string          destDir;
    JobState        state;
    ProgressTracker progress;
    string          error;         // set on Failed
    string[]        decodedFiles;  // paths of output files
}

/// In-memory download queue.  Tracks queued and completed jobs this session.
final class DownloadQueue
{
private:
    DownloadJob[] _jobs;

public:
    size_t enqueue(BinaryPost post, string destDir)
    {
        DownloadJob job;
        job.post    = post;
        job.destDir = destDir;
        job.state   = JobState.Queued;
        _jobs ~= job;
        return _jobs.length - 1;   // index of the new job
    }

    ref DownloadJob job(size_t idx) { return _jobs[idx]; }

    DownloadJob[] jobs() { return _jobs; }

    size_t length() const { return _jobs.length; }
}
