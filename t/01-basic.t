use Test::More('tests', 15);
use MooseX::Declare;

BEGIN
{
    sub POE::Kernel::CATCH_EXCEPTIONS () { 0 }
    use_ok('POEx::ProxySession::Server');
    use_ok('POEx::ProxySession::Client');
}
use POE;

class Foo with POEx::Role::SessionInstantiation
{
    use aliased 'POEx::Role::Event';
    use aliased 'POEx::Role::ProxyEvent';
    use POEx::Types(':all');
    
    method setup(WheelID :$connection_id) is Event
    {
        Test::More::pass('Foo::setup called');
        
        $self->post
        (
            'Client',
            'publish',
            connection_id   => $connection_id,
            session_alias    => 'FooSession',
            session         => $self,
            return_event    => 'handle_publish'
        );
    }

    method handle_publish(Bool :$success, Str :$session_alias, Ref :$payload?) is Event
    {
        if($success)
        {
            Test::More::pass('publish successful');
            $self->post('Tester', 'continue');
        }
        else
        {
            Test::More::fail('publish not successful');
            Test::More::BAIL_OUT($$payload);
        }
    }

    method foo(Str $arg1) is (Event, ProxyEvent) { Test::More::pass('Foo::foo called'); }
    method bar(Int $arg1) is (Event, ProxyEvent) { Test::More::pass('Foo::bar called'); }
    method yar(Bool $blat) is (Event, ProxyEvent)
    { 
        Test::More::pass('Foo::yar called'); 
        $self->post
        (
            'Client',
            'rescind',
            session => $self,
            return_event => 'handle_rescind',
        );
    }

    method handle_rescind(Bool :$success, Str :$session_name, Ref :$payload?) is Event
    {
        if($success)
        {
            Test::More::pass('rescind successful');
            $self->post('Tester', 'finish');
            $self->clear_alias;
            $self->poe->kernel->detach_myself;
        }
        else
        {
            Test::More::fail('rescind failed');
            Test::More::BAIL_OUT($$payload);
        }
    }
}

class Tester with POEx::Role::SessionInstantiation
{
    use POEx::Types(':all');
    use aliased 'POEx::Role::Event';
    
    has server => ( is => 'rw', isa => 'Ref');
    has client => ( is => 'rw', isa => 'Ref');
    has connection_id => (is => 'rw', isa => 'Int');

    after _start(@args) is Event
    {
        my $server = POEx::ProxySession::Server->new
        (
            listen_ip   => '127.0.0.1',
            listen_port => 56789,
            alias       => 'Server',
            options     => { trace => 1, debug => 1 },
        );

        my $client = POEx::ProxySession::Client->new
        ( 
            alias   => 'Client',
            options => { trace => 1, debug => 1 },
        );

        Foo->new
        (
            alias => 'foo',
            options     => { trace => 1, debug => 1 },
        );

        $self->post
        (
            'Client', 
            'connect', 
            remote_address  => '127.0.0.1', 
            remote_port     => 56789,
            return_session  => $self->alias,
            return_event    => 'post_connect'
        );

        $self->server($server);
        $self->client($client);
    }

    method post_connect(WheelID :$connection_id, Str :$remote_address, Int :$remote_port) is Event
    {
        Test::More::pass('Tester::post_connect called');
        
        $self->connection_id($connection_id);

        $self->post
        (
            'foo',
            'setup',
            connection_id => $connection_id,
        );
    }

    method continue() is Event
    {
        Test::More::pass('Tester::continue called');
        $self->post
        (
            'Client',
            'subscribe',
            connection_id   => $self->connection_id,
            to_session      => 'FooSession',
            return_event    => 'post_subscription',
        );
    }

    method post_subscription(Bool :$success, Str :$session_name, Ref :$payload?) is Event
    {
        if($success)
        {
            Test::More::pass('Subscription successful');
            $self->post
            (
                'Client',
                'server_listing',
                connection_id   => $self->connection_id,
                return_event    => 'post_listing',
            );

        }
        else
        {
            Test::More::fail('subscribe failed');
            Test::More::BAIL_OUT($$payload);
        }
    }

    method post_listing(Bool :$success, ArrayRef :$payload) is Event
    {
        if($success && (@$payload == 1) && $payload->[0] eq 'FooSession')
        {
            Test::More::pass('Listing successful');

            $self->post
            (
                'FooSession',
                'foo',
                'string',
            );

            $self->post
            (
                'FooSession',
                'bar',
                1,
            );

            $self->post
            (
                'FooSession',
                'yar',
                0,
            );
        }
        else
        {
            Test::More::fail('listing failed');
            Test::More::BAIL_OUT('Something horrible went wrong here');
        }
    }

    method finish() is Event
    {
        Test::More::pass('finish called');
        $self->clear_alias;
        $self->post('Client', 'unsubscribe', session_name => 'FooSession', return_event => 'done');
    }

    method done() is Event
    {
        Test::More::pass('all done');
        $self->post('Server', 'shutdown');
        $self->post('Client', 'shutdown');
    }
}

Tester->new(alias => 'Tester', options => {debug => 1, trace => 1});

POE::Kernel->run();

pass('done');
