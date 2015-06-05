#!/usr/bin/perl

# stream to this with cat | curl -s -T - -H Expect: http://localhost:3000/any/name
# stream from this with curl -s http://localhost:3000/any/name

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

my %open;

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
    app->log->debug("$path -> OPENED FOR WRITE");
    unlink "$cloud_storage_path$path" if -e "$cloud_storage_path$path";
    my $file = $open{$path} = Mojo::Asset::File->new(path => "$cloud_storage_path$path", cleanup => 0);
    # TODO what if already open?
    # TODO notify any readers
    # TODO implement append
}

sub put_recv {
    my ($path, $data) = @_;
    app->log->debug(sprintf "%s -> WRITE %d bytes", $path, length $data);
    $open{$path}->add_chunk($data);
    # TODO notify any readers
}

sub put_close {
    my ($path) = @_;
    app->log->debug("$path -> CLOSED FOR WRITE");
    delete $open{$path};
    # TODO notify any readers
}

sub get_send {
    my ($path, $controller) = @_;
    app->log->debug("$path -> GET");
    $controller->res->code(200)->content->asset(Mojo::Asset::File->new(path => "$cloud_storage_path$path"));
    $controller->rendered;
    #$controller->write_chunk(Mojo::Asset::File->new(path => "$cloud_storage_path$path"), sub { $controller->finish });
    # TODO if not exists, wait until exists or closed
    # TODO tail behavior -- should wait when sent until close and watch for more
    # TODO consider last=x param
}

app->start;
