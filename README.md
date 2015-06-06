# ☁|

Stream from command line to the cloud and back.

## Server

    # start server as docker container (localhost:8080)
    docker run -d -p 8080:80 kevineye/cloudpipe
    
    # run without docker (requires Mojolicious)
    server.pl daemon -l 'http://*:8080'

## Lite client (curl)

    # pipe to cloud
    something | curl -fsS -T - -H Expect: http://localhost:8080/anyname
    
    # pipe from cloud
    curl -fsSN http://localhost:8080/anyname

### Features

 - Unlike most HTTP clients, the input and output are streamed
 - Reading can start before writing (and will wait for a writer).
 - Reading will start from the beginning of the file and will continue to stream until all writers disconnect.
 - Multiple clients can read at the same time.
 - Files are stored and can be re-streamed.
