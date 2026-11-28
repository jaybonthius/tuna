# files

Visits files by path in buffers and saves them, byte for byte. Reading and writing run in jobs, so a slow disk never stops typing; the open files come back at the next start, and the files visited last are kept as a list.
