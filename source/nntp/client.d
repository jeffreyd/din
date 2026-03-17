module nntp.client;

import std.format    : format;
import std.algorithm : min;
import std.conv      : to;
import std.exception : enforce;

import nntp.tls      : TlsSocket;
import nntp.commands;
import model.header  : Header;
import model.server  : ServerConfig;

final class NntpClient
{
private:
    TlsSocket _sock;

public:
    /// Connect to the server described by cfg and authenticate.
    void connect(ServerConfig cfg)
    {
        enforce(cfg.tls, "Plain-text NNTP (no TLS) not yet supported");

        _sock = new TlsSocket();
        _sock.connect(cfg.host, cfg.port);

        // Read server greeting (200 or 201).
        auto greeting = parseResponse(_sock.readLine());
        enforce(greeting.code == 200 || greeting.code == 201,
                "Unexpected greeting: " ~ greeting.code.to!string ~
                " " ~ greeting.message);

        // Authenticate.
        if (cfg.user.length > 0)
        {
            _sock.writeLine("AUTHINFO USER " ~ cfg.user);
            auto r1 = expect([381, 281]);   // 381 = need password, 281 = accepted already

            if (r1.code == 381)
            {
                _sock.writeLine("AUTHINFO PASS " ~ cfg.pass);
                auto r2 = parseResponse(_sock.readLine());
                if (r2.code != 281)
                    throw new NntpAuthException(
                        "Authentication failed: " ~ r2.code.to!string ~
                        " " ~ r2.message);
            }
        }
    }

    /// Send GROUP, return article range info.
    GroupInfo selectGroup(string name)
    {
        _sock.writeLine("GROUP " ~ name);
        auto r = expect([211]);
        return parseGroupInfo(r.message, name);
    }

    /// Fetch headers for article numbers [from, to] via XOVER.
    Header[] fetchHeaders(long from, long to)
    {
        _sock.writeLine(format!"XOVER %d-%d"(from, to));
        expect([224]);

        Header[] headers;
        foreach (line; _sock.readMultiLine())
        {
            if (line.length > 0)
                headers ~= parseXoverLine(line);
        }
        return headers;
    }

    /// Fetch the body of a single article by message-id.
    string fetchBody(string messageId)
    {
        _sock.writeLine("BODY " ~ messageId);
        expect([222]);

        import std.array : join;
        return _sock.readMultiLine().join("\n");
    }

    /// Fetch head + body of a single article by message-id.
    string fetchArticle(string messageId)
    {
        _sock.writeLine("ARTICLE " ~ messageId);
        expect([220]);

        import std.array : join;
        return _sock.readMultiLine().join("\n");
    }

    void close()
    {
        if (_sock)
        {
            try { _sock.writeLine("QUIT"); } catch (Exception) {}
            _sock.close();
            _sock = null;
        }
    }

private:
    NntpResponse expect(int[] codes)
    {
        auto r = parseResponse(_sock.readLine());
        import std.algorithm : canFind;
        if (!codes.canFind(r.code))
            throw new NntpException(
                "Expected " ~ codes.to!string ~ ", got " ~
                r.code.to!string ~ " " ~ r.message);
        return r;
    }
}
