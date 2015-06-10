#!/usr/bin/perl

BEGIN {
    $ENV{MOJO_INACTIVITY_TIMEOUT} = 0;
}

use Mojolicious::Lite;
use autodie;
use File::Path 'make_path';
use File::MimeInfo::Magic 'magic';
use Mojo::JSON 'encode_json';
use Scalar::Util 'weaken';

app->log->level('debug');

my $cloud_storage_path = $ENV{CLOUD_STORAGE} || '/tmp/cloud';
-d $cloud_storage_path or make_path $cloud_storage_path or die "cannot create $cloud_storage_path; override with CLOUD_STORAGE environment variable\n";

my $expiration_seconds = ($ENV{EXPIRATION_DAYS} || 7) * 86400;

my %writing;
my %reading;
my @listening;

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

post '/_/api/cleanup' => sub {
    my $c = shift;
    cleanup_fs();
    $c->render(json => {});
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
        } elsif (-f $file and $file =~ m{\.txt$}) {
            my $name = substr $file, 1 + length $cloud_storage_path;
            $name =~ s{\.txt}{};
            my @stat = stat $file;
            push @{$data->{files}}, {
                name => $name,
                sending => ($reading{$name} ? Mojo::JSON->true : Mojo::JSON->false),
                receiving => ($writing{$name} ? Mojo::JSON->true : Mojo::JSON->false),
                size => $stat[7],
                mtime => $stat[9],
            };
        }
    }
    return $data;
}

get '/*' => sub {
    my $c = shift;
    my ($name, $file, $args) = parse_req($c->req);
    if ($c->req->headers->te && $c->req->headers->te =~ /\bchunked\b/) {
        # client wants streaming updates
        $c->res->headers->content_type(guess_type($file));

        app->log->info("GET $name");
        app->log->debug("$name -> BEGIN SENDING");

        create_dirs($file);

        my $size = -s $file;
        my $pos = exists $args->{last} ? ($args->{last} > $size ? $size : $size - $args->{last}) : 0;

        my $cb;
        $cb = sub {
            my $asset= Mojo::Asset::File->new(path => $file, cleanup => 0);

            # must have been truncated; return to beginning
            $pos = 0 if $pos > $asset->size;

            # we've sent the whole file
            if ($pos == $asset->size) {

                # if the file is not still being written, close it
                unless ($writing{$name}) {
                    get_close($name, $cb);
                    $c->finish;
                } else {
                    app->log->debug("$name -> FINISHED SENDING, WAITING");
                }

                # if it is still being written, our cb will be activated later by the writer
            } else {
                # send the next chunk, and then call the callback again
                my $data = $asset->get_chunk($pos);
                $pos += length $data;
                app->log->debug(sprintf "%s -> SEND %d bytes", $name, length $data);
                $c->write_chunk($data, $cb);
            }

        };

        # setup cleanup
        $c->on(
            finish => sub {
                get_close($name, $cb);
            }
        );

        # open the file by listing it in the readers for this path
        $reading{$name} ||= [];
        push @{$reading{$name}}, $cb;

        # call the callback to get things started
        # unless the file doesn't exist yet... we'll do nothing now and wait
        my $asset = Mojo::Asset::File->new(path => $file, cleanup => 0);
        if ($asset->size > 0 && $pos < $asset->size) {
            $cb->();
        } else {
            app->log->debug("$name -> WAITING FOR INITIAL DATA");
        }

        send_status();
        $c->render_later;
    } else {
        # client did not ask for streaming updates
        app->log->info("GET $name");
        if (-f $file and -r $file) {
            $c->res->headers->content_type(guess_type($file));
            my $asset = Mojo::Asset::File->new(path => $file, cleanup => 0);
            my $size = $asset->size;
            if (exists $args->{last}) {
                $asset->end_range($size);
                $size = $args->{last} unless $args->{last} > $size;
                $asset->start_range($asset->end_range - $size);
                $c->res->headers->content_length($size);
            }
            if ($size == 0) {
                $c->render(data => '');
            } else {
                $c->res->content->asset($asset);
                $c->rendered(200);
            }
        } else {
            $c->reply->not_found;
        }
    }
};

sub get_close {
    my ($path, $cb) = @_;
    app->log->debug("$path -> CLOSING");
    $reading{$path} = [ grep { $_ ne $cb } @{$reading{$path}} ];
    delete $reading{$path} if @{$reading{$path}} == 0;
    send_status();
}

del '/*' => sub {
    my $c = shift;
    my ($name, $file, $args) = parse_req($c->req);
    app->log->info("DELETE $name");
    if (-f $file) {
        unlink $file;
        cleanup_fs();
    }
    delete $reading{$name};
    delete $writing{$name};
    $c->render(json => {});
};

hook after_build_tx => sub {
    my $tx = shift;
    weaken $tx;

    $tx->req->content->on(
        body => sub {
            my ($content) = @_;
            put_open($tx->req) if $tx->req->method eq 'PUT';
        }
    );

    $tx->req->content->on(
        read => sub {
            my ($content, $bytes) = @_;
            put_recv($tx->req, $bytes) if $tx->req->method eq 'PUT';
        }
    );

    $tx->on(
        finish => sub {
            put_close($tx->req) if $tx->req->method eq 'PUT';
        }
    );
};

put '*' => sub {
    my $c  = shift;
    $c->render(data => '');
};

sub put_open {
    my ($req) = @_;
    my ($name, $file, $args) = parse_req($req);
    app->log->info("PUT name");
    app->log->debug("name -> BEGIN RECEIVING");
    unlink $file if -e $file and not $args->{append};
    create_dirs($file);
    if ($writing{$name}) {
        $writing{$name}{count}++;
    } else {
        $writing{$name} = {
            asset => Mojo::Asset::File->new(path => $file, cleanup => 0),
            count => 1,
        };
    }
    my $asset = $writing{$name}{asset};
    open $asset->{handle}, ($args->{append} ? '>>' : '>'), $asset->path; # hack to force read-write open and trunc/append
    $_->() for @{$reading{$name} || []};
    send_status();
}

sub put_recv {
    my ($req, $data) = @_;
    my ($name, $file, $args) = parse_req($req);
    app->log->debug(sprintf "%s -> RECEIVED %d bytes", $name, length $data);
    $writing{$name}{asset}->add_chunk($data);
    $_->() for @{$reading{$name} || []};
}

sub put_close {
    my ($req) = @_;
    my ($name, $file, $args) = parse_req($req);
    app->log->debug("$name -> FINISHED RECEIVING");
    if ($writing{$name}) {
        $writing{$name}{count}--;
        delete $writing{$name} if $writing{$name}{count} <= 0;
    }
    $_->() for @{$reading{$name} || []};
    send_status();
}

sub create_dirs {
    my ($file) = @_;
    $file =~ s{/[^/]+$}{};
    make_path $file unless -d $file;
}

sub cleanup_fs {
    my @to_scan = $cloud_storage_path;
    while (my $file = pop @to_scan) {
        if (-d $file) {
            my $dh;
            my $c = 0;
            opendir $dh, $file;
            for (reverse readdir $dh) {
                next if $_ eq '.' or $_ eq '..';
                $c++;
                push @to_scan, "$file/$_";
            }
            closedir $dh;
            if ($c == 0 and $file ne $cloud_storage_path) {
                rmdir $file;
                my $name = substr $file, length $cloud_storage_path;
                app->log->info("CLEANUP $name (empty)");
            }
        } elsif (-f $file and $file =~ m{\.txt$}) {
            my @stat = stat $file;
            if (time - $stat[9] > $expiration_seconds) {
                my $name = substr $file, 1 + length $cloud_storage_path;
                $name =~ s{\.txt}{};
                app->log->info("CLEANUP $name (old)");
                unlink $file;
            }
        }
    }
}

sub guess_type {
    my $file = shift;
    return magic($file) || (-T $file && 'text/plain') || 'application/octet-stream';
}

sub parse_req {
    my ($req) = @_;
    my $args = {};
    my $path = $req->url->path;

    # parse query params
    my $q = $req->query_params;
    $args->{append} = 1 if $q->param('append');
    $args->{last} = $q->param('last') if defined $q->param('last');
    $args->{last} = 0 if $q->param('end');

#    # parse "command line" options
#    my @argv = split /\s+/, $path;
#    my @names;
#
#    while (@argv) {
#        my $a = shift @argv;
#        if ($a =~ m{^-}) {
#            if ($a eq '-e' or $a eq '--end') {
#                $args->{last} = 0;
#            } elsif ($a eq '-a' or $a eq '--append') {
#                $args->{append} = 1;
#            } elsif ($a eq '-l' or $a eq '--last') {
#                $args->{last} = shift @argv;
#            }
#        } else {
#            push @names, $a;
#        }
#    }

    # extract and normalize "name" (URL path)
#    my $name = $names[0] || 'default';
    my $name = $path;
    $name =~ s{^/+|/+$}{}g;
    $name =~ s{[^0-9a-zA-Z_./]+}{-}g;
    $name =~ s{^-+|-+$}{}g;
    $name =~ s{/+}{/}g;

    # transform name to "file" (storage path)
    my $file = "$cloud_storage_path/$name.txt";

#    warn encode_json [($name, $file, $args)];

    return ($name, $file, $args);
}

Mojo::IOLoop->recurring(900 => \&cleanup_fs);

app->start;
