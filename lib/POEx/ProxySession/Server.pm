use 5.010;

use MooseX::Declare;

class POEx::ProxySession::Server with POEx::Role::TCPServer
{
    use 5.010;
    use POEx::ProxySession::Types(':all');
    use POEx::Types(':all');
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use aliased 'POEx::Role::Event';
    
    has sessions =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        is          => 'rw',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_sessions',
        provides    => 
        {
            get     => 'get_session',
            set     => 'set_session',
            delete  => 'delete_session',
            count   => 'has_sessions',
            keys    => 'all_session_names',
        }
    );



    method handle_inbound_data(ProxyMessage $data, WheelID $id) is Event
    {
        my %result = ( 'type' => 'result' );

        given($data->{type})
        {
            when ('register')
            {
                eval
                {
                    $self->register_session($data, $id);
                    $result{success} = 1;
                };

                @result{'success', 'payload'} = ( 0, $@ ) if $@;
            }
            when ('listing')
            {
                @result{'success', 'payload'} = ( 1, [$self->all_session_names]);
            }
            when ('subscribe')
            {
                eval
                {
                    @result{'success', 'payload'} = ( 1, $self->subscribe_session($data->{payload}) );
                };

                @result{'success', 'payload'} = ( 0, $@ ) if $@;
            }
            when ('deliver')
            {
                eval
                {
                    $self->deliver_message($data, $id);
                    $result{success} = 1;
                };
                
                @result{'success', 'payload'} = ( 0, $@ ) if $@;
            }
            when ('result')
            {
            }
        }

        $self->get_wheel($id)->put(\$result);
    }

    method register_session(ProxyMessage $data, WheelID $id)
    {
    }

    method subscribe_session(Str $session) returns (Moose::Meta::Class)
    {
    }

    method deliver_message(ProxyMessage $data)
    {
    }
}

1;
__END__
 
