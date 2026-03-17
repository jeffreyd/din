module model.group;

struct Group
{
    string name;
    long   total;
    long   unread;
    bool   subscribed = true;
}
