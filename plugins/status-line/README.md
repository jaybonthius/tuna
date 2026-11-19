# status-line

A status line at the foot of each view in the layout, made of segments that any plugin defines and places in a table: by default whether the file is modified, the buffer's name, the line and column of point, where point is in the buffer as a percentage and the size of the region on the left, and the major and minor modes' lighters on the right. Each window's status line is drawn in the window's own element of the layout, marked with its keymap and each segment's, so a click on a segment is a mouse key found in the segment's keymap, then the line's.
