module model.server;

struct ServerConfig
{
    string name;
    string host;
    ushort port        = 563;
    bool   tls         = true;
    string user;
    string pass;
    int    connections = 4;
}
