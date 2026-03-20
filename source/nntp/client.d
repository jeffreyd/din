module nntp.client;

import std.format    : format;
import std.algorithm : min;
import std.conv      : to;
import std.exception : enforce;

import nntp.tls      : TlsSocket;
import nntp.commands : NntpException, NntpAuthException, NntpResponseException,
                       NntpResponse, parseResponse, GroupInfo, parseGroupInfo;
import model.server  : ServerConfig;

final class NntpClient
{
private:
    TlsSocket    _sock;
    ServerConfig _cfg;
    bool         _nonBlocking;

public:
    /// Connect to the server described by cfg and authenticate.
    void connect(ServerConfig cfg)
    {
        _cfg = cfg;
        doConnect();
    }

    /// Send GROUP, return article range info.  Auto-reconnects on timeout.
    GroupInfo selectGroup(string name)
    {
        return withRetry!GroupInfo({
            _sock.writeLine("GROUP " ~ name);
            auto r = expect([211]);
            return parseGroupInfo(r.message, name);
        });
    }

    /// Stream raw XOVER lines to onLine instead of
    /// returning a Header[].  Zero heap allocation for the array.
    /// onRetry is called (before reconnecting) if a connection error occurs
    /// mid-stream, giving the caller a chance to roll back any partial writes.
    /// groupName is re-sent via GROUP after reconnect so strict servers that
    /// require a selected group before XOVER don't return 412.
    void fetchHeadersEach(string groupName, long from, long to,
                          scope void delegate() onRetry,
                          scope void delegate(string) onLine)
    {
        void doFetch()
        {
            _sock.writeLine(format!"XOVER %d-%d"(from, to));
            expect([224]);
            _sock.readMultiLineEach(onLine);
        }

        try
        {
            doFetch();
        }
        catch (NntpAuthException e)    { throw e; }
        catch (NntpResponseException e){ throw e; }
        catch (Exception)
        {
            onRetry();
            reconnect();
            // Re-select the group; some servers require GROUP before XOVER.
            _sock.writeLine("GROUP " ~ groupName);
            expect([211]);
            doFetch();
        }
    }

    /// Fetch the body of a single article by message-id.  Auto-reconnects.
    string fetchBody(string messageId)
    {
        return withRetry!string({
            _sock.writeLine("BODY " ~ messageId);
            expect([222]);
            import std.array : join;
            return _sock.readMultiLine().join("\n");
        });
    }

    /// Fetch the full group list via LIST.  Returns group names only.
    string[] fetchGroupList()
    {
        return withRetry!(string[])({
            _sock.writeLine("LIST");
            expect([215]);
            string[] names;
            foreach (line; _sock.readMultiLine())
            {
                import std.string : indexOf;
                auto sp = line.indexOf(' ');
                string name = sp > 0 ? line[0 .. sp] : line;
                if (name.length > 0)
                    names ~= name;
            }
            return names;
        });
    }

    /// Fetch head + body of a single article by message-id.  Auto-reconnects.
    string fetchArticle(string messageId)
    {
        return withRetry!string({
            _sock.writeLine("ARTICLE " ~ messageId);
            expect([220]);
            import std.array : join;
            return _sock.readMultiLine().join("\n");
        });
    }

    /// Switch to non-blocking I/O (for use with FiberScheduler).
    /// Must be called after connect().  Survives reconnects.
    void setNonBlocking()
    {
        _nonBlocking = true;
        _sock.setNonBlocking();
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
    void doConnect()
    {
        _sock = new TlsSocket();
        _sock.connect(_cfg.host, _cfg.port);

        // Read server greeting (200 or 201).
        auto greeting = parseResponse(_sock.readLine());
        enforce(greeting.code == 200 || greeting.code == 201,
                "Unexpected greeting: " ~ greeting.code.to!string ~
                " " ~ greeting.message);

        // Authenticate.
        if (_cfg.user.length > 0)
        {
            _sock.writeLine("AUTHINFO USER " ~ _cfg.user);
            auto r1 = expect([381, 281]);

            if (r1.code == 381)
            {
                _sock.writeLine("AUTHINFO PASS " ~ _cfg.pass);
                auto r2 = parseResponse(_sock.readLine());
                if (r2.code != 281)
                    throw new NntpAuthException(
                        "Authentication failed: " ~ r2.code.to!string ~
                        " " ~ r2.message);
            }
        }
    }

    void reconnect()
    {
        if (_sock)
        {
            try { _sock.close(); } catch (Exception) {}
            _sock = null;
        }
        doConnect();
        if (_nonBlocking)
            _sock.setNonBlocking();
    }

    /// Run fn(); on connection-level exceptions, reconnect and try once more.
    /// NntpResponseException (server-side 4xx/5xx) is re-thrown without
    /// reconnecting — the connection is still usable.
    T withRetry(T)(scope T delegate() fn)
    {
        try
        {
            return fn();
        }
        catch (NntpAuthException e)
        {
            throw e;   // never retry auth failures
        }
        catch (NntpResponseException e)
        {
            throw e;   // server said no — don't burn a reconnect
        }
        catch (Exception)
        {
            reconnect();
            return fn();
        }
    }

    NntpResponse expect(int[] codes)
    {
        auto r = parseResponse(_sock.readLine());
        import std.algorithm : canFind;
        if (!codes.canFind(r.code))
            throw new NntpResponseException(
                "Expected " ~ codes.to!string ~ ", got " ~
                r.code.to!string ~ " " ~ r.message,
                r.code);
        return r;
    }
}
