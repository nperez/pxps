use 5.010;
use MooseX::Declare;

role POEx::ProxySession::MessageSender
{
    use 5.010;
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use POEx::Types(':all');
    use POEx::ProxySession::Types(':all');
    use Storable('nfreeze');

    use aliased 'POEx::Role::Event';

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

    method next_message_id() returns (Int)
    {
        state $id = 0;
        return $id++;
    }
    
    method send_result(Bool :$success, ProxyMessage :$original, Ref :$payload?, WheelID :$wheel_id) is Event
    {
        my $msg = 
        {
            id      => $original->{id},
            type    => 'result', 
            success => $success,
        };

        $msg->{payload} = nfreeze($payload) if $payload;

        $self->get_wheel($wheel_id)->put($msg);
    }

    method send_message(Str :$type, Ref :$payload, WheelID :$wheel_id) is Event
    {
        my $msg = { type => $type, id => $self->next_message_id(), payload => nfreeze($payload) };
        $self->get_wheel($wheel_id)->put($msg);
    }

    method return_to_sender
    (   ProxyMessage :$message, 
        WheelID :$wheel_id, 
        SessionID :$return_session, 
        Str :$return_event, 
        Ref :$tag?
    ) is Event
    {
        $message->{id} = $self->next_message_id();
        $self->set_pending($message->{id}, { tag => $tag, return_session => $return_session, return_event => $return_event });
        $self->get_wheel($wheel_id)->put($message);
    }
    
}
