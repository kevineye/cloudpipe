# cloudpipe

## Server

    # start server as docker container (localhost:9729)
    docker run -d -p 9729:80 kevineye/cloudpipe
    
    # run without docker (requires Mojolicious)
    server.pl daemon -l 'http://*:9729'

## Lite client (curl)

    # pipe to cloud
    something | curl -fsS -T - -H Expect: http://localhost:9729/anyname
    
    # pipe from cloud
    curl -fsSN -H TE:chunked http://localhost:9729/anyname

    # like a real command
    cloud() { test -t 0 && curl -fsSN -H TE:chunked http://localhost:9729/${1-default} || curl -fsS -T - -H Expect: http://localhost:9729/${1-default}; }


### Features

 - Unlike most HTTP clients, the input and output are streamed
 - Reading can start before writing (and will wait for a writer).
 - Reading will start from the beginning of the file and will continue to stream until all writers disconnect.
 - Multiple clients can read and write at the same time.
 - Files are stored and can be re-streamed.

### REST API

 - `PUT /*` upload a file
   - Use `?append=1` to append to the stream if it already exists
 - `GET /*` download a file
   - With `TE: chunked` header, the connection will be held open, streaming data as long as a writer is writing.
 - `DELETE /*` delete a file
 - `GET /_/api/list` return JSON describing all streams available to read
   - With `TE: chunked` header, the connection will be held open, sending new JSON messages for each status change.
 - `POST /_/api/cleanup` trigger file and directory cleanup (also runs every 10 minutes)
