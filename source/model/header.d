module model.header;

/// A single article header as returned by XOVER.
struct Header
{
    long   number;
    string subject;
    string from;
    string date;
    string messageId;
    string references;
    ulong  bytes;
    uint   lines;
}
