# status-line

A status line at the foot of each view in the layout, made of segments that any plugin defines and places in a table: by default whether the file is modified, the buffer's name and the line and column of point on the left, and the major and minor modes' lighters on the right. Each window's status line is a view of one buffer whose atoms are the placed segments, so a click on a segment is a mouse key found in its kind's keymap.
