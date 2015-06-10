#!/usr/bin/perl

BEGIN {
    $ENV{MOJO_INACTIVITY_TIMEOUT} = 0;
}

use Mojolicious::Lite;
use autodie;
use File::Path 'make_path';
use Mojo::JSON 'encode_json';
use Scalar::Util 'weaken';

app->log->level('debug');

my $cloud_storage_path = $ENV{CLOUD_STORAGE} || '/tmp/cloud';
-d $cloud_storage_path or make_path $cloud_storage_path or die "cannot create $cloud_storage_path; override with CLOUD_STORAGE environment variable\n";

my %writing;
my %reading;
my @listening;

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

#get '/' => sub {
#    my $c = shift;
#    $c->render(text => "...");
#};

get '/_/api/list' => sub {
    my $c = shift;
    if ($c->req->headers->te && $c->req->headers->te =~ /\bchunked\b/) {
        # client wants streaming updates
        $c->res->headers->content_type('application/json');
        push @listening, $c;
        $c->write_chunk(encode_json generate_status_json());
    } else {
        # client did not ask for streaming updates
        $c->render(json => generate_status_json());
    }
};

sub send_status {
    @listening = grep { $_->tx } @listening;
    my $status = encode_json generate_status_json();
    $_->write_chunk($status) for @listening;
}

sub generate_status_json {
    my $data = { files => [] };
    my @to_scan = $cloud_storage_path;
    while (my $file = pop @to_scan) {
        if (-d $file) {
            my $dh;
            opendir $dh, $file;
            for (reverse readdir $dh) {
                next if $_ eq '.' or $_ eq '..';
                push @to_scan, "$file/$_";
            }
            closedir $dh;
        } elsif (-f $file) {
            my $path = substr $file, 1 + length $cloud_storage_path ;
            my @stat = stat $file;
            push @{$data->{files}}, {
                name => $path,
                sending => ($reading{$path} ? Mojo::JSON->true : Mojo::JSON->false),
                receiving => ($writing{$path} ? Mojo::JSON->true : Mojo::JSON->false),
                size => $stat[7],
                mtime => $stat[9],
            };
        }
    }
    return $data;
}

get '/*' => sub {
    my $c = shift;
    if ($c->req->headers->te && $c->req->headers->te =~ /\bchunked\b/) {
        # client wants streaming updates
        get_send($c->req->url->path, $c);
        $c->render_later;
    } else {
        # client did not ask for streaming updates
        $c->reply->asset(Mojo::Asset::File->new(path => $cloud_storage_path . $c->req->url->path));
    }
};

sub put_open {
    my ($path) = @_;
    app->log->debug("$path -> BEGIN RECEIVING");
    unlink "$cloud_storage_path$path" if -e "$cloud_storage_path$path";
    my $file = $writing{$path} = Mojo::Asset::File->new(path => "$cloud_storage_path$path", cleanup => 0);
    open $file->{handle}, '>', $file->path; # hack to force read-write open and trunc
    $_->() for @{$reading{$path} || []};
    send_status();
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
    send_status();
}

sub get_send {
    my ($path, $controller) = @_;

    my $pos = 0;
    app->log->debug("$path -> BEGIN SENDING");

    my $cb;
    $cb = sub {
        my $file = Mojo::Asset::File->new(path => "$cloud_storage_path$path", cleanup => 0);

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
    my $file = Mojo::Asset::File->new(path => "$cloud_storage_path$path", cleanup => 0);
    if ($file->size > 0) {
        $cb->();
    } else {
        app->log->debug("$path -> WAITING FOR INITIAL DATA");
    }

    send_status();
}

sub get_close {
    my ($path, $cb) = @_;
    app->log->debug("$path -> CLOSING");
    $reading{$path} = [ grep { $_ ne $cb } @{$reading{$path}} ];
    delete $reading{$path} if @{$reading{$path}} == 0;
    send_status();
}

app->start;
