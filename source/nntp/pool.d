module nntp.pool;

import model.server : ServerConfig;
import nntp.client  : NntpClient;

/// A single NNTP connection for segment downloading.
final class NntpPool
{
private:
    NntpClient _client;

public:
    this(ServerConfig server)
    {
        _client = new NntpClient();
        _client.connect(server);
    }

    string fetchBody(string messageId)
    {
        return _client.fetchBody(messageId);
    }

    void close()
    {
        if (_client) { _client.close(); _client = null; }
    }
}
