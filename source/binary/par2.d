module binary.par2;

import std.process   : execute;
import std.file      : dirEntries, SpanMode, remove;
import std.string    : splitLines;
import std.algorithm : endsWith;
import std.regex     : regex, matchFirst;

/// Result of a par2 verify/repair run.
struct Par2Result
{
    bool     success;    /// true = files verified OK (or successfully repaired)
    bool     repaired;   /// true = repair was needed and succeeded
    string[] output;     /// combined output lines from par2
}

/// Find par2 index files in destDir, then run par2 verify and (if needed)
/// repair using the system `par2` binary.
/// Returns immediately with success=true if no par2 index file is found.
/// Optionally deletes all .par2 files from destDir after success.
Par2Result runPar2(string destDir, bool deletePar2Files = false)
{
    Par2Result result;

    string par2Index = findPar2Index(destDir);
    if (par2Index.length == 0)
    {
        result.success = true;
        return result;
    }

    // Verify.
    auto vr = execute(["par2", "verify", par2Index]);
    result.output ~= vr.output.splitLines;

    if (vr.status == 0)
    {
        result.success = true;
        if (deletePar2Files)
            deletePar2InDir(destDir);
        return result;
    }

    // Verify failed — attempt repair.
    auto rr = execute(["par2", "repair", par2Index]);
    result.output ~= rr.output.splitLines;
    result.repaired = true;
    result.success  = (rr.status == 0);

    if (result.success && deletePar2Files)
        deletePar2InDir(destDir);

    return result;
}

// Find the par2 index file (not a recovery volume) in destDir.
// Index files end in .par2 but NOT in .vol<N>+<N>.par2.
private string findPar2Index(string destDir)
{
    static auto volRe = regex(`\.vol\d+\+\d+\.par2$`);
    try
    {
        foreach (entry; dirEntries(destDir, SpanMode.shallow))
        {
            if (!entry.isFile) continue;
            if (!entry.name.endsWith(".par2")) continue;
            if (!matchFirst(entry.name, volRe).empty) continue;  // skip volumes
            return entry.name;
        }
    }
    catch (Exception) {}
    return "";
}

// Delete all .par2 files in destDir.
private void deletePar2InDir(string destDir)
{
    try
    {
        foreach (entry; dirEntries(destDir, SpanMode.shallow))
        {
            if (entry.isFile && entry.name.endsWith(".par2"))
                try { remove(entry.name); } catch (Exception) {}
        }
    }
    catch (Exception) {}
}
