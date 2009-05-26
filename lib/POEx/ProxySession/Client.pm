use 5.010;

use MooseX::Declare;

class POEx::ProxySession::Client with POEx::Role::TCPClient
{
    use 5.010;
    use POEx::ProxySession::Types(':all');
    use POEx::Types(':all');
    use POE::Filter::Reference;
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use Storable('thaw', 'nfreeze');
    use aliased 'POEx::Role::Event';

    has pending =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        is          => 'rw',
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
            count   => 'count_sessions',
            keys    => 'all_session_names',
            exists  => 'has_session',
        }
    );

    after _start(@args) is Event
    {
        $self->filter(POE::Filter::Reference->new());
    }

    after handle_on_connect(GlobRef $socket, Str $address, Int $port, WheelID $id) is Event
    {
        $self->send_message({ type => 'listing'}, $self->last_wheel, $self->ID, 'receive_listing'); 
    }

    method handle_inbound_data(ProxyMessage $data, WheelID $id) is Event
    {
        given($data->{type})
        {
            when ('result')
            {
                if($self->has_pending($data->{id}))
                {
                    my $pending = $self->get_pending($data->{id});
                    $self->post($pending->{sender}, $pending->{event_name}, $data, $id);
                }
                else
                {
                    warn q|Received a result for something we didn't send out|;
                    return;
                }
            }
            when ('deliver')
            {
                if($self->has_session($data->{to}))
                {
                    my $payload = thaw($data->{payload});
                    my ($event, @args) = ($payload->{event}, @{ $payload->{args} });
                    my $session = $self->get_session($data->{to});

                    $self->post($session, $event, @args);
                }
                else
                {
                    warn q|Received a delivery for someone that isn't us|;
                    $self->get_wheel($id)->put
                    (
                        { 
                            type    => 'result', 
                            success => 0, 
                            payload => nfreeze('Recipient unknown')
                        }
                    );
                    return;
                }
            }
        }
    }

    method subscribe() is Event
    {
        
    }

    method unsubscribe() is Event
    {

    }

    method publish() is Event
    {

    }

    method unpublish() is Event
    {
    }
    
    method receive_listing(ProxyMessage $data, WheelID $id) is Event
    {
    }

    method handle_on_subscribe(ProxyMessage $data, WheelID $id) is Event
    {
    }
    
    method send_result(Bool $success, Ref $payload, WheelID $id)
    {
        $self->get_wheel($id)->put
        (
            {
                type    => 'result', 
                success => $success,
                payload => nfreeze($payload);
    }

    method send_message(ProxyMessage $data, WheelID $id, SessionID $sender, Str $event_name)
    {
        state $my_id = 1;
        $data->{'id'} = $my_id;
        $self->set_pending($my_id++, { sender => $sender, event_name => $event_name });
        $self->get_wheel($id)->put($data);

    }

}
