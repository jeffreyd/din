module nntp.tls;

import deimos.openssl.ssl;
import deimos.openssl.err;
import std.socket    : TcpSocket, InternetAddress;
import std.string    : toStringz, fromStringz;
import std.exception : enforce;
import std.conv      : to;

import nntp.commands : NntpException;

// ---------------------------------------------------------------------------
// SSL_set_tlsext_host_name is a macro in OpenSSL — deimos may not expose it
// directly.  We call SSL_ctrl ourselves with the well-known constants.
// ---------------------------------------------------------------------------
private enum int  SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
private enum long TLSEXT_NAMETYPE_host_name    = 0;

private void setSniHostname(SSL* ssl, string host) nothrow
{
    import std.string : toStringz;
    SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME,
             TLSEXT_NAMETYPE_host_name,
             cast(void*) host.toStringz);
}

// ---------------------------------------------------------------------------
// TlsSocket — line-oriented TLS socket for NNTP
// ---------------------------------------------------------------------------

final class TlsSocket
{
private:
    TcpSocket _socket;
    SSL_CTX*  _ctx;
    SSL*      _ssl;

    ubyte[65_536] _buf;
    size_t        _start;
    size_t        _end;

public:
    this()
    {
        // OpenSSL 1.1+ initialises itself automatically, but calling these
        // is harmless (they become no-ops) and keeps 1.0.x builds happy.
        SSL_library_init();
        SSL_load_error_strings();

        auto method = TLS_client_method();
        enforce(method !is null, "Failed to obtain TLS client method");

        _ctx = SSL_CTX_new(method);
        enforce(_ctx !is null, "Failed to create SSL_CTX: " ~ sslErrorString());
    }

    ~this()
    {
        close();
        if (_ctx) { SSL_CTX_free(_ctx); _ctx = null; }
    }

    /// Connect to host:port and complete the TLS handshake.
    void connect(string host, ushort port)
    {
        _socket = new TcpSocket();
        _socket.connect(new InternetAddress(host, port));

        _ssl = SSL_new(_ctx);
        enforce(_ssl !is null, "Failed to create SSL object: " ~ sslErrorString());

        setSniHostname(_ssl, host);

        int fd = cast(int) _socket.handle;
        enforce(SSL_set_fd(_ssl, fd) == 1,
                "SSL_set_fd failed: " ~ sslErrorString());

        int rc = SSL_connect(_ssl);
        if (rc != 1)
        {
            int err = SSL_get_error(_ssl, rc);
            throw new NntpException("TLS handshake failed (SSL error " ~
                                    err.to!string ~ "): " ~ sslErrorString());
        }
    }

    /// Send a line.  The CRLF terminator is appended automatically.
    void writeLine(string line)
    {
        string       data  = line ~ "\r\n";
        const(ubyte)[] buf = cast(const(ubyte)[]) data;
        size_t sent = 0;

        while (sent < buf.length)
        {
            int n = SSL_write(_ssl,
                              cast(const(void)*) (buf.ptr + sent),
                              cast(int) (buf.length - sent));
            if (n <= 0)
            {
                int err = SSL_get_error(_ssl, n);
                throw new NntpException("SSL write failed (SSL error " ~
                                        err.to!string ~ "): " ~ sslErrorString());
            }
            sent += n;
        }
    }

    /// Read one CRLF-terminated line.  The terminator is stripped.
    string readLine()
    {
        while (true)
        {
            // Scan current buffer for a newline.
            foreach (i; _start .. _end)
            {
                if (_buf[i] == '\n')
                {
                    string line = (cast(char[]) _buf[_start .. i]).idup;
                    _start = i + 1;
                    if (line.length > 0 && line[$ - 1] == '\r')
                        line = line[0 .. $ - 1];
                    return line;
                }
            }
            fillBuffer();
        }
    }

    /// Read a dot-stuffed multi-line response body (stops at bare ".").
    string[] readMultiLine()
    {
        string[] lines;
        while (true)
        {
            string line = readLine();
            if (line == ".")
                break;
            if (line.length > 0 && line[0] == '.')
                line = line[1 .. $];   // dot-unstuffing
            lines ~= line;
        }
        return lines;
    }

    void close()
    {
        if (_ssl)    { SSL_free(_ssl);       _ssl    = null; }
        if (_socket) { _socket.close();      _socket = null; }
    }

private:
    void fillBuffer()
    {
        // Compact: move unconsumed data to the front.
        if (_start > 0)
        {
            immutable size_t rem = _end - _start;
            _buf[0 .. rem] = _buf[_start .. _end];
            _end   = rem;
            _start = 0;
        }

        enforce(_end < _buf.length, "TLS read buffer full without finding newline");

        int n = SSL_read(_ssl,
                         cast(void*) (_buf.ptr + _end),
                         cast(int)   (_buf.length - _end));
        if (n <= 0)
        {
            int err = SSL_get_error(_ssl, n);
            throw new NntpException("SSL read failed (SSL error " ~
                                    err.to!string ~ "): " ~ sslErrorString());
        }
        _end += n;
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private string sslErrorString() nothrow
{
    try
    {
        char[256] buf = 0;
        ERR_error_string_n(ERR_get_error(), buf.ptr, buf.length);
        return fromStringz(buf.ptr).idup;
    }
    catch (Exception)
        return "(unknown SSL error)";
}
