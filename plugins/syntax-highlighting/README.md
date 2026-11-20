# syntax-highlighting

Colours the text of buffers. A language registers a highlighter for its major mode or its language: a worker of `jobs`, the layers it fills and the input it needs. Each buffer with a highlighter has a job that follows its edits and sets the spans that changed, so no highlighting runs on the main thread. The job's loop is the plain library `(syntax-highlighting job)`.
