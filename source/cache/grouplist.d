module cache.grouplist;

import std.file   : exists, readText, write, mkdirRecurse;
import std.path   : buildPath, dirName;
import std.string : strip, splitLines;

// The groups file lives next to the cache dir: ~/.din/groups
string groupsFilePath(string cacheDir)
{
    return buildPath(dirName(cacheDir), "groups");
}

// Load subscribed group names from a simple text file (one name per line).
// Lines starting with '#' and blank lines are ignored.
string[] loadSubscribed(string path)
{
    if (!exists(path)) return [];
    string[] result;
    foreach (line; readText(path).splitLines)
    {
        string s = strip(line);
        if (s.length > 0 && s[0] != '#')
            result ~= s;
    }
    return result;
}

void saveSubscribed(string path, string[] groups)
{
    import std.array : join;
    mkdirRecurse(dirName(path));
    write(path, groups.join("\n") ~ "\n");
}
