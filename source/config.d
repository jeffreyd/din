module config;

import std.file      : readText, exists;
import std.string    : strip, splitLines, startsWith, indexOf, lastIndexOf;
import std.conv      : to, ConvException;
import std.path      : expandTilde;
import std.process   : environment;

import model.server;

struct AppOptions
{
    string downloadDir;
    bool   autoPar2           = true;
    bool   deletePar2         = true;
    string cacheDir;
    int    maxHeaderAgeDays   = 30;
    string editor;
}

struct AppConfig
{
    ServerConfig[] servers;
    AppOptions     options;

    /// Returns a pointer to the named server, or null if not found.
    ServerConfig* serverByName(string name) nothrow
    {
        foreach (ref s; servers)
            if (s.name == name) return &s;
        return null;
    }
}

AppConfig loadConfig(string path = "~/.din/config")
{
    AppConfig cfg;

    cfg.options.downloadDir = expandTilde("~/Downloads/usenet");
    cfg.options.cacheDir    = expandTilde("~/.din/cache");
    cfg.options.editor      = environment.get("VISUAL",
                                  environment.get("EDITOR", "vi"));

    string expanded = expandTilde(path);
    if (!exists(expanded))
        return cfg;

    string text = readText(expanded);

    string       section;
    ServerConfig current;
    bool         inServer = false;

    void flushServer()
    {
        if (inServer)
        {
            cfg.servers ~= current;
            current   = ServerConfig.init;
            inServer  = false;
        }
    }

    foreach (rawLine; splitLines(text))
    {
        string line = strip(rawLine);

        if (line.length == 0 || line[0] == ';' || line[0] == '#')
            continue;

        // Section header: [server "name"]  or  [options]
        if (line[0] == '[')
        {
            auto end = line.indexOf(']');
            if (end < 0) continue;
            string header = strip(line[1 .. end]);

            if (header.startsWith("server"))
            {
                flushServer();
                section  = "server";
                inServer = true;

                // Extract name from quotes: [server "name"]
                auto q1 = header.indexOf('"');
                auto q2 = header.lastIndexOf('"');
                if (q1 >= 0 && q2 > q1)
                    current.name = header[q1 + 1 .. q2];
                else
                    current.name = strip(header["server".length .. $]);
            }
            else if (header == "options")
            {
                flushServer();
                section = "options";
            }
            else
            {
                flushServer();
                section = header;
            }
            continue;
        }

        // key = value
        auto eq = line.indexOf('=');
        if (eq < 0) continue;

        string key = strip(line[0 .. eq]);
        string val = strip(line[eq + 1 .. $]);

        // Strip inline comments
        auto semi = val.indexOf(';');
        if (semi >= 0) val = strip(val[0 .. semi]);

        if (section == "server" && inServer)
        {
            switch (key)
            {
                case "host":
                    current.host = val;
                    break;
                case "port":
                    try { current.port = val.to!ushort; } catch (ConvException) {}
                    break;
                case "tls":
                    current.tls = (val == "true" || val == "1" || val == "yes");
                    break;
                case "user":
                    current.user = val;
                    break;
                case "pass":
                    current.pass = val;
                    break;
                case "connections":
                    try { current.connections = val.to!int; } catch (ConvException) {}
                    break;
                default:
                    break;
            }
        }
        else if (section == "options")
        {
            switch (key)
            {
                case "download_dir":
                    cfg.options.downloadDir = expandTilde(val);
                    break;
                case "auto_par2":
                    cfg.options.autoPar2 = (val == "true" || val == "1");
                    break;
                case "delete_par2":
                    cfg.options.deletePar2 = (val == "true" || val == "1");
                    break;
                case "cache_dir":
                    cfg.options.cacheDir = expandTilde(val);
                    break;
                case "max_header_age_days":
                    try { cfg.options.maxHeaderAgeDays = val.to!int; } catch (ConvException) {}
                    break;
                case "editor":
                    cfg.options.editor = val;
                    break;
                default:
                    break;
            }
        }
    }

    flushServer();
    return cfg;
}
