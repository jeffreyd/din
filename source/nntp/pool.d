module nntp.pool;

import core.thread.fiber  : Fiber;

import model.server       : ServerConfig;
import nntp.client        : NntpClient;
import nntp.scheduler     : FiberScheduler;

// ---------------------------------------------------------------------------
// NntpPool — parallel NNTP connection pool
// ---------------------------------------------------------------------------

final class NntpPool
{
private:
    NntpClient[] _clients;

public:
    this(ServerConfig server)
    {
        int n = server.connections > 0 ? server.connections : 1;
        _clients.length = n;
        foreach (i; 0 .. n)
        {
            _clients[i] = new NntpClient();
            _clients[i].connect(server);
            _clients[i].setNonBlocking();
        }
    }

    /// Fetch bodies (or full articles) for all msgIds in parallel.
    /// Pass useArticle=true to issue ARTICLE (head+body) instead of BODY.
    void fetchBodies(string[] msgIds,
                     void delegate(size_t idx, string body) onFetch,
                     void delegate(size_t idx, string msg)  onError,
                     bool useArticle = false)
    {
        int total = cast(int) msgIds.length;
        if (total == 0) return;

        int n = cast(int) _clients.length;
        if (n > total) n = total;

        // Shared work counter: safe without locks (cooperative scheduling).
        int nextIdx = 0;

        auto sched = new FiberScheduler();

        foreach (ci; 0 .. n)
            sched.addFiber(spawnFiber(_clients[ci], msgIds, total,
                                      &nextIdx, onFetch, onError, useArticle));

        sched.run();
    }

    void close()
    {
        foreach (c; _clients)
            if (c) c.close();
        _clients = null;
    }

private:
    // Each call creates a fresh frame; the delegate inside captures `client`
    // from that frame, not from the enclosing foreach body.
    static Fiber spawnFiber(NntpClient client,
                             string[] msgIds,
                             int total,
                             int* nextIdx,
                             void delegate(size_t, string) onFetch,
                             void delegate(size_t, string) onError,
                             bool useArticle)
    {
        return new Fiber(delegate void()
        {
            while (true)
            {
                int idx = (*nextIdx)++;
                if (idx >= total) break;

                string msgId = msgIds[idx];
                if (msgId.length == 0)
                {
                    onError(idx, "empty message-id");
                    continue;
                }

                try
                {
                    string body = useArticle
                        ? client.fetchArticle(msgId)
                        : client.fetchBody(msgId);
                    onFetch(idx, body);
                }
                catch (Exception e)
                {
                    onError(idx, e.msg);
                }
            }
        }, 512 * 1024);
    }
}
