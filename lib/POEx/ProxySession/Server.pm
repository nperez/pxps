package POEx::ProxySession::Server;

#ABSTRACT: Hosts published sessions and routes proxy message

use MooseX::Declare;

=head1 SYNOPSIS

class Flarg 
{
    with 'POEx::Role::SessionInstantiation';

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

class POEx::ProxySession::Server
{
    with 'POEx::ProxySession::MessageSender';
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

    has delivered_store =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_delivereds',
        provides    => 
        {
            get     => 'get_delivered',
            set     => 'set_delivered',
            delete  => 'delete_delivered',
            count   => 'count_delivereds',
            keys    => 'all_delivered_keys',
            values  => 'all_delivered_values',
            exists  => 'has_delivered',
        }
    );

=method handle_inbound_data(ProxyMessage $data, WheelID $id) is Event

Our implementation of handle_inbound_data expects a ProxyMessage as data. Here 
is where the handling and routing of messages lives. The following types of 
messages are handled here: publish, rescind, listing, subscribe, deliver, and
result. 

=cut

    method handle_inbound_data(ProxyMessage $data, WheelID $id) is Event
    {
        if ($data->{type} eq 'publish')
        {
            $self->yield('publish_session', $data, $id);
        }
        elsif ($data->{type} eq 'rescind')
        {
            $self->yield('rescind_session', $data, $id);
        }
        elsif ($data->{type} eq 'listing')
        {
            $self->yield('get_listing', $data, $id);
        }
        elsif ($data->{type} eq 'subscribe')
        {
            $self->yield('subscribe_session', $data, $id);
        }
        elsif ($data->{type} eq 'deliver')
        {
            $self->yield('deliver_message', $data, $id);
        }
        elsif ($data->{type} eq 'result')
        {
            $self->yield('handle_delivered', $data, $id);
        }
        else
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
    
    with 'POEx::Role::TCPServer';

=method after _start(@args) is Event

The _start method is advised to hardcode the filter to use as a 
POE::Filter::Reference instance.

=cut

    after _start(@args) is Event
    {
        $self->filter(POE::Filter::Reference->new());
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
sends it on to that session's connection. Sets a delivered message.

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
        
        $self->set_delivered($data->{id}, $id);
        $self->get_wheel($wheel_id)->put($data);
    }

=method handle_delivered(ProxyMessage $data, WheelID $id) is Event

This method handles result messages from delivered messages. All messages that 
go through the system are expected to return a result message indicating 
success or failure.

=cut
    method handle_delivered(ProxyMessage $data, WheelID $id) is Event
    {
        if($self->has_pending($data->{id}))
        {
            my $pending = $self->delete_pending($data->{id});
            $self->post($pending->{return_session}, $pending->{return_event}, $data, $id, $pending->{tag});
        }
        elsif($self->has_delivered($data->{id}))
        {
            my $to_id = $self->delete_delivered($data->{id});
            $self->get_wheel($to_id)->put($data);
        }
        else
        {
            warn q|Received an unexpected result message|;
        }
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

