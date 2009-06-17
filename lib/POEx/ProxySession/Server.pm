package POEx::ProxySession::Server;
use 5.010;

#ABSTRACT: Hosts published sessions and routes proxy message

use MooseX::Declare;
$Storable::forgive_me = 1;

=head1 SYNOPSIS

class Flarg with POEx::Role::SessionInstantiation
{
    after _start(@args) is Event
    {
        POEx::ProxySession::Server->new
        (
            listen_ip   => '127.0.0.1',
            listen_port => 56789,
            alias       => 'Server',
            options     => { trace => 1, debug => 1 },
        );
    }
}


=cut

class POEx::ProxySession::Server with (POEx::Role::TCPServer, POEx::ProxySession::MessageSender)
{
    use 5.010;
    use POEx::ProxySession::Types(':all');
    use POEx::Types(':all');
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use Storable('thaw', 'nfreeze');
    use POE::Filter::Reference;
    use aliased 'POEx::Role::Event';

=attr sessions metaclass => MooseX::AttributeHelpers::Collection::Hash

This attribute is used to store the published sessions. It has no accessors
beyond what is provided by AttributeHelpers:

    provides    => 
    {
        get     => 'get_session',
        set     => 'set_session',
        delete  => 'delete_session',
        count   => 'count_sessions',
        keys    => 'all_session_names',
        exists  => 'has_session',
    }

The stored structure looks like the following:

    Session =>
    {
        name    => isa SessionAlias,
        methods => HashRef,
        id      => isa WheelID,
    }

=cut

    has sessions =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_sessions',
        provides    => 
        {
            get     => 'get_session',
            set     => 'set_session',
            delete  => 'delete_session',
            count   => 'count_sessions',
            keys    => 'all_session_names',
            exists  => 'has_session',
        }
    );

=method after _start(@args) is Event

The _start method is advised to hardcode the filter to use as a 
POE::Filter::Reference instance.

=cut

    after _start(@args) is Event
    {
        $self->filter(POE::Filter::Reference->new());
    }

=method handle_inbound_data(ProxyMessage $data, WheelID $id) is Event

Our implementation of handle_inbound_data expects a ProxyMessage as data. Here 
is where the handling and routing of messages lives. The following types of 
messages are handled here: publish, rescind, listing, subscribe, deliver, and
result. 

=cut

    method handle_inbound_data(ProxyMessage $data, WheelID $id) is Event
    {
        given($data->{type})
        {
            when ('publish')
            {
                $self->yield('publish_session', $data, $id);
            }
            when ('rescind')
            {
                $self->yield('rescind_session', $data, $id);
            }
            when ('listing')
            {
                $self->yield('get_listing', $data, $id);
            }
            when ('subscribe')
            {
                $self->yield('subscribe_session', $data, $id);
            }
            when ('deliver')
            {
                $self->yield('deliver_message', $data, $id);
            }
            when ('result')
            {
                $self->yield('handle_pending', $data, $id);
            }
            default
            {
                my $type = $data->{type};
                $self->yield
                (
                    'send_result', 
                    success     => 0,
                    original    => $data, 
                    wheel_id    => $id, 
                    payload     => \"Unknown message type '$type'"
                );
            }
        }
    }

=method rescind_session(ProxyMessage $data, WheelID $id) is Event

This handles rescinding of a published session. No payload on success.

=cut 

    method rescind_session(ProxyMessage $data, WheelID $id) is Event
    {
        my $payload = thaw($data->{payload});
        my $session = $payload->{session_alias};

        if(!$session)
        {
            $self->yield
            (
                'send_result', 
                success     => 0, 
                original    => $data, 
                wheel_id    => $id,
                payload     => \'Session alias is required', 
            );
        }
        elsif(!$self->has_session($session))
        {
            $self->yield
            (
                'send_result', 
                success     => 0, 
                original    => $data, 
                wheel_id    => $id,
                payload     => \"Session '$session' doesn't exist", 
            );
        }
        else
        {
            $self->delete_session($session);
            
            $self->yield
            (
                'send_result', 
                success     => 1, 
                original    => $data, 
                wheel_id    => $id
            );
        }
    }

=method publish_session(ProxyMessage $data, WheelID $id) is Event

This method handles session publication. Payload on success is the session 
alias

=cut

    method publish_session(ProxyMessage $data, WheelID $id) is Event
    {
        my $payload = thaw($data->{payload});

        my $alias = $payload->{session_alias};
        my $name = $payload->{session_name};
        my $methods = $payload->{methods};

        if(!$alias)
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \'Session alias must be defined'
            );
        }
        elsif($self->has_session($alias))
        {
            $self->yield
            (
                'send_result',
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \"Session '$alias' already exists"
            );
        }
        elsif(!$name)
        {
            $self->yield
            (
                'send_result', 
                success     => 0,
                original    => $data, 
                wheel_id    => $id, 
                payload     => \'Session name is required'
            );
        }
        else
        {
            $self->set_session($alias, { name => $name, methods => $methods, wheel => $id });
            
            $self->yield
            (
                'send_result', 
                success     => 1,
                original    => $data, 
                wheel_id    => $id,
                payload     => \$alias
            );
        }
    }
=method subscribe_session(ProxyMessage $data, WheelID $id) is Event

This method handles subscription requests. Payload on success is a hashref:

    {
        session => isa SessionAlias,
        methods => HashRef,
    }

=cut

    method subscribe_session(ProxyMessage $data, WheelID $id) is Event
    {
        my $session_name = $data->{to};
        if(!$self->has_session($session_name))
        {
            $self->yield
            (
                'send_result', 
                success     => 0, 
                original    => $data, 
                wheel_id    => $id,
                payload     => \"Session '$session_name' doesn't exist", 
            );
            return;
        }

        my $result = { session => $session_name, methods => $self->get_session($session_name)->{methods} };

        $self->yield
        (
            'send_result', 
            success     => 1,
            original    => $data, 
            wheel_id    => $id, 
            payload     => $result
        );
    }

=method deliver_message(ProxyMessage $data, WheelID $id) is Event

This method does message delivery by doing a lookup of the alias to the real
session name, and rewriting the message header to point to that session, then
sends it on to that session's connection. Sets a pending message.

=cut

    method deliver_message(ProxyMessage $data, WheelID $id) is Event
    {
        my $session = $data->{to};
        
        if(!$self->has_session($session))
        {
            $self->yield
            (
                'send_result', 
                success     => 0, 
                original    => $data, 
                wheel_id    => $id,
                payload     => \"Session '$session' doesn't exist", 
            );
            return;
        }
        my $lookup = $self->get_session($session);
        
        $data->{to} = $lookup->{name};
        my $wheel_id = $lookup->{wheel};
        
        $self->set_pending($data->{id}, $id);
        $self->get_wheel($wheel_id)->put($data);
    }

=method handle_pending(ProxyMessage $data, WheelID $id) is Event

This method handles pending result messages. All messages that go through
the system are expected to return a result message indicating success or
failure.

=cut
    method handle_pending(ProxyMessage $data, WheelID $id) is Event
    {
        if(!$self->has_pending($data->{id}))
        {
            warn q|Received an unexpected result message|;
            return;
        }

        my $to_id = $self->delete_pending($data->{id});
        $self->get_wheel($to_id)->put($data);
    }

=method get_listing(ProxyMessage $data, WheelID $id) is Event

This method handles listing requests from clients. Should always succeed.
Payload is an ArrayRef[SessionAlias].

=cut

    method get_listing(ProxyMessage $data, WheelID $id) is Event
    {
        $self->yield
        (
            'send_result', 
            success     => 1,
            original    => $data, 
            wheel_id    => $id, 
            payload     => [ $self->all_session_names ]
        );
    }
}

1;
__END__
=head1 DESCRIPTION

POEx::ProxySession::Server is a lightweight network server that handles 
storage and listing of published sessions, and routing of proxied messages
between connected clients.

