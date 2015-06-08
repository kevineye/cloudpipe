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
    curl -fsSN http://localhost:9729/anyname

    # like a real command
    cloud() { test -t 0 && curl -fsSN http://localhost:9729/${1-default} || curl -fsS -T - -H Expect: http://localhost:9729/${1-default}; }


### Features

 - Unlike most HTTP clients, the input and output are streamed
 - Reading can start before writing (and will wait for a writer).
 - Reading will start from the beginning of the file and will continue to stream until all writers disconnect.
 - Multiple clients can read at the same time.
 - Files are stored and can be re-streamed.
