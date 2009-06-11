use 5.010;

use MooseX::Declare;
$Storable::forgive_me = 1;

class POEx::ProxySession::Server with (POEx::Role::TCPServer, POEx::ProxySession::MessageSender)
{
    use 5.010;
    use POEx::ProxySession::Types(':all');
    use POEx::Types(':all');
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use Storable('thaw', 'nfreeze');
    use aliased 'POEx::Role::Event';
    
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

    after _start(@args) is Event
    {
        $self->filter(POE::Filter::Reference->new());
    }

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
                $self->yield('return_error', $data, $id, "Unknown message type '$type'");
            }
        }
    }

    method rescind_session(ProxyMessage $data, WheelID $id) is Event
    {
        my $payload = thaw($data->{payload});
        my $session = $payload->{session_alias};

        if(!$session)
        {
            $self->yield('return_error', $data, $id, 'Session alias is required');
        }
        elsif(!$self->has_session($session))
        {
            $self->yield('return_error', $data, $id, "Session '$session' doesn't exist");
        }
        else
        {
            $self->delete_session($session);
            $self->yield('return_success', $data, $id);
        }
    }
    
    method publish_session(ProxyMessage $data, WheelID $id) is Event
    {
        my $payload = thaw($data->{payload});

        my $alias = $payload->{session_alias};
        my $name = $payload->{session_name};
        my $meta = $payload->{meta};

        if(!$alias)
        {
            $self->yield('return_error', $data, $id, 'Session alias must be defined');
        }
        elsif($self->has_session($alias))
        {
            $self->yield('return_error', $data, $id, "Session '$alias' already exists");
        }
        elsif(!$name)
        {
            $self->yield('return_error', $data, $id, 'Session name is required');
        }
        else
        {
            bless($meta, 'Moose::Meta::Class');
            $self->set_session($alias, { name => $name, meta => $meta, wheel => $id });
            $self->yield('return_success', $data, $id, \$alias);
        }
    }

    method subscribe_session(ProxyMessage $data, WheelID $id) is Event
    {
        my $session_name = $data->{to};
        if(!$self->has_session($session_name))
        {
            $self->return_error($data, $id, "Session '$session_name' does not exist");
            return;
        }

        my $result = { session => $session_name, meta => $self->get_session($session_name)->{meta} };

        $self->return_success($data, $id, $result);
    }

    method deliver_message(ProxyMessage $data, WheelID $id) is Event
    {
        my $session = $data->{to};
        
        if(!$self->has_session($session))
        {
            $self->send_error($data, $id, "Session '$session' does not exist");
            return;
        }
        
        my $lookup = $self->get_session($session);
        
        $data->{to} = $lookup->{name};
        my $wheel_id = $lookup->{wheel};
        
        $self->set_pending($data->{id}, $id);
        $self->get_wheel($wheel_id)->put($data);
    }

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

    method get_listing(ProxyMessage $data, WheelID $id) is Event
    {
        $self->yield('return_success', $data, $id, [ $self->all_session_names ]);
    }

    method return_error(ProxyMessage $data, WheelID $id, Str $msg) is Event
    {
        my $result = { success => 0, type => 'result', id => $data->{id}, payload => nfreeze(\$msg) };
        $self->get_wheel($id)->put($result);
    }

    method return_success(ProxyMessage $data, WheelID $id, Ref $payload?) is Event
    {
        my $result = { success => 1, type => 'result', id => $data->{id} } ; 
        $result->{payload} = nfreeze($payload) if defined($payload);
        $self->get_wheel($id)->put($result);
    }
}

1;
__END__
 
