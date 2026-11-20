# jsonrpc

JSON-RPC 2.0 with a program over its standard input and output, in `Content-Length` frames, as language servers speak it. A request pauses its task until the answer comes; the program's own requests and notifications reach the procedures given with `jsonrpc:handlers`. Frames are read and parsed in a job with the chez-json-rpc libraries, and each connection keeps an events log of what it sent and received and of its program's standard error.
