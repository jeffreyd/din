module model.binary;

/// An assembled multipart binary post (one file from N segments).
struct BinaryPost
{
    string   baseName;        // subject stripped of part markers (filename)
    string   poster;          // from field of first part
    string   date;            // date of first part
    uint     totalParts;      // M in (N/M)
    uint     presentParts;    // how many we have in cache
    ulong    totalBytes;      // sum of segment byte counts
    string[] messageIds;      // [partNum-1] = msgId; empty string if part missing
    long     firstArticleNum; // article number of the lowest-numbered part (for sorting)
    bool     isComplete;      // presentParts == totalParts
    bool     hasNfo;          // baseName looks like an NFO file
    bool     hasPar2;         // baseName looks like a par2 file
}
