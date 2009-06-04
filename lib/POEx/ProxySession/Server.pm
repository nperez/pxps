use 5.010;

use MooseX::Declare;

class POEx::ProxySession::Server with POEx::Role::TCPServer
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

    has pending =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_pending',
        provides    => 
        {
            get     => 'get_pending',
            set     => 'set_pending',
            delete  => 'delete_pending',
            count   => 'count_pending',
            exists  => 'has_pending',
        }

    );

    after _start(@args) is Event
    {
        $self->filter(POE::Filter::Reference->new());
    }

    method handle_inbound_data(ProxyMessage $data, WheelID $id) is Event
    {
        my %result = ( 'type' => 'result', 'id' => $data->{id} );

        given($data->{type})
        {
            when ('publish')
            {
                eval
                {
                    $self->publish_session($data, $id);
                    $result{success} = 1;
                };

                if($@)
                {
                    @result{'success', 'payload'} = ( 0, nfreeze( \$@ ) );
                    $self->get_wheel($id)->put(\%result);
                    return;
                }
            }
            when ('rescind')
            {
                eval
                {
                    $self->rescind_session($data, $id);
                    $result{success} = 1;
                };

                if($@)
                {
                    @result{'success', 'payload'} = ( 0, nfreeze( \$@ ) );
                    $self->get_wheel($id)->put(\%result);
                    return;
                }
            }
            when ('listing')
            {
                @result{'success', 'payload'} = ( 1, nfreeze( [$self->all_session_names] ) );
                $self->get_wheel($id)->put(\%result);
            }
            when ('subscribe')
            {
                eval
                {
                    @result{'success', 'payload'} = ( 1, nfreeze( $self->subscribe_session($data->{to}) ) );
                };

                if($@)
                {
                    @result{'success', 'payload'} = ( 0, nfreeze( \$@ ) );
                    $self->get_wheel($id)->put(\%result);
                    return;
                }

            }
            when ('deliver')
            {
                eval
                {
                    $self->deliver_message($data, $id);
                };
                
                if($@)
                {
                    @result{'success', 'payload'} = ( 0, nfreeze( \$@ ) );
                    $self->get_wheel($id)->put(\%result);
                    return;
                }

            }
            when ('result')
            {
                my $to_id = $self->delete_pending($id);
                $self->get_wheel($to_id)->put($data);
                return;
            }
        }

        $self->get_wheel($id)->put(\%result);
    }

    method rescind_session(ProxyMessage $data, WheelID $id)
    {
        my $payload = thaw($data->{payload});

        my $session = $payload->{session};
        die "Session name required"
            if not defined($session);
        
        die "Session '$session' doesn't exist"
            if not $self->has_session($session);
        
        $self->delete_session($session);
    }
    
    method publish_session(ProxyMessage $data, WheelID $id)
    {
        my $payload = thaw($data->{payload});

        my $session = $payload->{session};
        die "Session name required"
            if not defined($session);
        
        die "Session '$session' already exists"
            if $self->has_session($session);
        
        my $meta = $payload->{meta};
        bless($meta, 'Moose::Meta::Class');

        die 'Moose::Meta::Class required'
            if not blessed($meta) or
            not $meta->isa('Moose::Meta::Class');

        $self->set_session($session, { meta => $meta, wheel => $id });
    }

    method subscribe_session(Str $session_name)
    {
        die "Session '$session_name' does not exist"
            if not $self->has_session($session_name);

        return { session => $session_name, meta => $self->get_session($session_name)->{meta} };
    }

    method deliver_message(ProxyMessage $data, WheelID $id)
    {
        my $session = $data->{to};

        die "Session '$session' does not exist"
            if not $self->has_session($session);
        
        my $wheel_id = $self->get_session($session)->{wheel};
        $self->set_pending($wheel_id, $id);
        $self->get_wheel($wheel_id)->put($data);
    }
}

1;
__END__
 
