module model.thread;

import model.header : Header;
import model.binary : BinaryPost;

enum ItemKind { Text, Binary }

/// A unified thread-list entry: either a plain text article or an assembled binary.
struct ThreadItem
{
    ItemKind   kind;
    Header     header;   // valid when kind == Text
    BinaryPost binary;   // valid when kind == Binary
}
