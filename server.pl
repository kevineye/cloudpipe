#!/usr/bin/perl

# stream to this with cat | curl -fsS -T - -H Expect: http://localhost:3000/any/name
# stream from this with curl -fsSN http://localhost:3000/any/name
# slow-write with perl -e 'syswrite STDOUT, $_ and sleep 1 for 0..9'
# slow-read with perl -e 'sleep 1 while sysread STDIN, $s, 1 and syswrite STDOUT, $s'

# TODO add web site to list, edit, view/watch, add "copy curl", "install" options
# TODO add other backends (e.g. pastebin, gist)
# TODO add --edit option that uploads, waits for web edit, then re-downloads
# TODO add expiration on files (deleted after ___ days)

BEGIN {
    $ENV{MOJO_INACTIVITY_TIMEOUT} = 0;
}
# try app->defaults(inactivity_timeout => 0)?

use Mojolicious::Lite;
use autodie;
use File::Path 'make_path';
use Scalar::Util 'weaken';

app->log->level('debug');

my $cloud_storage_path = $ENV{CLOUD_STORAGE} || '/tmp/cloud';
-d $cloud_storage_path or make_path $cloud_storage_path or die "cannot create $cloud_storage_path; override with CLOUD_STORAGE environment variable\n";

my %writing;
my %reading;

hook after_build_tx => sub {
    my $tx = shift;
    weaken $tx;
  
    $tx->req->content->on(
        body => sub {
            my ($content) = @_;
            put_open($tx->req->url->path) if $tx->req->method eq 'PUT';
        }
    );

    $tx->req->content->on(
        read => sub {
            my ($content, $bytes) = @_;
            put_recv($tx->req->url->path, $bytes) if $tx->req->method eq 'PUT';
        }
    );

    $tx->on(
        finish => sub {
            put_close($tx->req->url->path) if $tx->req->method eq 'PUT';
        }
    );
};

put '*' => sub {
    my $c  = shift;
    put_close($c->req->url->path);
    $c->render(data => '');
};

get '*' => sub {
    my $c = shift;
    get_send($c->req->url->path, $c);
    $c->render_later;
    #$c->render(data => $cache{$c->param('id')});
};

sub put_open {
    my ($path) = @_;
    app->log->debug("$path -> BEGIN RECEIVING");
    unlink "$cloud_storage_path$path" if -e "$cloud_storage_path$path";
    $writing{$path} = Mojo::Asset::File->new(path => "$cloud_storage_path$path", cleanup => 0);
    $_->() for @{$reading{$path} || []};
    # TODO what if already open?
    # TODO implement append
}

sub put_recv {
    my ($path, $data) = @_;
    app->log->debug(sprintf "%s -> RECEIVED %d bytes", $path, length $data);
    $writing{$path}->add_chunk($data);
    $_->() for @{$reading{$path} || []};
}

sub put_close {
    my ($path) = @_;
    app->log->debug("$path -> FINISHED RECEIVING");
    delete $writing{$path};
    $_->() for @{$reading{$path} || []};
}

sub get_send {
    my ($path, $controller) = @_;

    my $file = Mojo::Asset::File->new(path => "$cloud_storage_path$path", cleanup => 0);
    my $pos = 0;
    app->log->debug("$path -> BEGIN SENDING");

    my $cb;
    $cb = sub {

        # must have been truncated; return to beginning
        $pos = 0 if $pos > $file->size;

        # we've sent the whole file
        if ($pos == $file->size) {

            # if the file is not still being written, close it
            unless ($writing{$path}) {
                get_close($path, $cb);
                $controller->finish;
            } else {
                app->log->debug("$path -> FINISHED SENDING, WAITING");
            }

            # if it is still being written, our cb will be activated later by the writer
        } else {
            # send the next chunk, and then call the callback again
            my $data = $file->get_chunk($pos);
            $pos += length $data;
            app->log->debug(sprintf "%s -> SEND %d bytes", $path, length $data);
            $controller->write_chunk($data, $cb);
        }

    };

    # setup cleanup
    $controller->on(
        finish => sub {
            get_close($path, $cb);
        }
    );

    # open the file by listing it in the readers for this path
    $reading{$path} ||= [];
    push @{$reading{$path}}, $cb;

    # call the callback to get things started
    # unless the file doesn't exist yet... we'll do nothing now and wait
    if ($file->size > 0) {
        $cb->();
    } else {
        app->log->debug("$path -> WAITING FOR INITIAL DATA");
    }

    # TODO fix bad FD on waiting for start
    # TODO consider last=x param
}

sub get_close {
    my ($path, $cb) = @_;
    app->log->debug("$path -> CLOSING");
    $reading{$path} = [ grep { $_ ne $cb } @{$reading{$path}} ];
    delete $reading{$path} if @{$reading{$path}} == 0;
}

app->start;
