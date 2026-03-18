module nntp.scheduler;

import core.thread.fiber            : Fiber;
import core.sys.posix.sys.select;

import nntp.tls : _schedulerYield;

// ---------------------------------------------------------------------------
// FiberScheduler
// ---------------------------------------------------------------------------
// Runs a set of D Fibers cooperatively using POSIX select() for I/O waiting.
//
// Usage:
//   auto sched = new FiberScheduler();
//   sched.addFiber(new Fiber({ ... }, 512*1024));
//   sched.run();   // blocks until all fibers complete
//
// Fibers that need to wait for I/O call nntp.tls._schedulerYield(fd, wantWrite)
// followed by Fiber.yield().  The scheduler moves them to a wait list, calls
// select(), and resumes them when the fd is ready.
// ---------------------------------------------------------------------------

final class FiberScheduler
{
private:
    Fiber[]  _runnable;

    struct Waiter
    {
        Fiber fiber;
        int   fd;
        bool  wantWrite;
    }
    Waiter[] _waiting;

    int _total;
    int _done;

public:
    void addFiber(Fiber f)
    {
        _runnable ~= f;
        _total++;
    }

    /// Called by nntp.tls from within a fiber to register an I/O wait.
    void registerWait(int fd, bool wantWrite)
    {
        auto f = Fiber.getThis();
        assert(f !is null, "registerWait called outside a fiber");
        _waiting ~= Waiter(f, fd, wantWrite);
    }

    /// Run all fibers to completion.
    void run()
    {
        _schedulerYield = &registerWait;
        scope (exit) _schedulerYield = null;

        while (_done < _total)
        {
            // Resume every runnable fiber once.
            Fiber[] nextRound;
            foreach (f; _runnable)
            {
                f.call();
                if (f.state == Fiber.State.TERM)
                    _done++;
                else if (!isWaiting(f))
                    nextRound ~= f;   // yielded without registering I/O wait
                // else: it's in _waiting, will be moved to _runnable when ready
            }
            _runnable = nextRound;

            if (_done >= _total) break;

            // When no runnable fibers remain, block in select() until at least
            // one waiting fd is ready, then move ready fibers to _runnable.
            if (_runnable.length == 0 && _waiting.length > 0)
                pollWaiting();
        }
    }

private:
    bool isWaiting(Fiber f)
    {
        foreach (ref w; _waiting)
            if (w.fiber is f) return true;
        return false;
    }

    void pollWaiting()
    {
        fd_set rset, wset;
        FD_ZERO(&rset);
        FD_ZERO(&wset);
        int maxfd = 0;

        foreach (ref w; _waiting)
        {
            if (w.wantWrite) FD_SET(w.fd, &wset);
            else             FD_SET(w.fd, &rset);
            if (w.fd > maxfd) maxfd = w.fd;
        }

        // 10 ms timeout so we never block forever if something goes wrong.
        timeval tv;
        tv.tv_sec  = 0;
        tv.tv_usec = 10_000;

        select(maxfd + 1, &rset, &wset, null, &tv);

        Waiter[] stillWaiting;
        foreach (ref w; _waiting)
        {
            bool ready = w.wantWrite
                ? (FD_ISSET(w.fd, &wset) != 0)
                : (FD_ISSET(w.fd, &rset) != 0);
            if (ready) _runnable ~= w.fiber;
            else       stillWaiting ~= w;
        }
        _waiting = stillWaiting;
    }
}
