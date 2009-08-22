package POEx::ProxySession::MessageSender;

#ABSTRACT: ProxySession utility Role for sending message

use MooseX::Declare;

role POEx::ProxySession::MessageSender
{
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use POEx::Types(':all');
    use POEx::ProxySession::Types(':all');
    use Storable('nfreeze');

    use aliased 'POEx::Role::Event';

=attr pending metaclass => MooseX::AttributeHelpers::Collection::Hash

pending stores context related data of messages where a result is expected.

It has no accessors beyond those provided by AttributeHelpers:

    provides    => 
    {
        get     => 'get_pending',
        set     => 'set_pending',
        delete  => 'delete_pending',
        count   => 'count_pending',
        exists  => 'has_pending',
    }

=cut

    has pending =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef[HashRef],
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
            values  => 'all_pending',
        }

    );

    has queue =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef[ArrayRef],
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_queue',
        provides    =>
        {
            get     => 'get_queued',
            set     => 'set_queued',
            delete  => 'delete_queued',
            count   => 'count_queued',
            exists  => 'has_queued',
            values  => 'all_queued',
            keys    => 'all_sessions_queued',
        }
    );

=method next_message_id() returns (Int)

This method returns the next message id to be used.

=cut
    
    my $id = 0;
    method next_message_id() returns (Int)
    {
        return $id++;
    }

=method send_result(Bool :$success, ProxyMessage :$original, Ref :$payload?, WheelID :$wheel_id) is Event

This is a convenience method for sending result messages to the original sender.

=cut

    method send_result(Bool :$success, ProxyMessage :$original, Ref :$payload?, WheelID :$wheel_id) is Event
    {
        my $msg = 
        {
            id      => $original->{id},
            type    => 'result', 
            success => $success,
        };

        $msg->{payload} = nfreeze($payload) if $payload;
        
        if($self->has_wheel($wheel_id))
        {
            $self->get_wheel($wheel_id)->put($msg);
        }
        else
        {
            my $queued = 
            {
                message => $msg,
                sender  => $self->poe->sender->ID,
            };
            
            $self->set_queued($wheel_id, [])
                if not $self->has_queued($wheel_id);
            push(@{ $self->get_queue($wheel_id) }, $queued);
        }
    }

=method send_message(Str :$type, Ref :$payload, WheelID :$wheel_id) is Event

This method creates a message with the provided payload and delivers it via the
connection that wheel_id references.

=cut

    method send_message(Str :$type, Ref :$payload, WheelID :$wheel_id) is Event
    {
        my $msg = { type => $type, id => $self->next_message_id(), payload => nfreeze($payload) };
        
        if($self->has_wheel($wheel_id))
        {
            $self->get_wheel($wheel_id)->put($msg);
        }
        else
        {
            my $queued = 
            {
                message => $msg,
                sender  => $self->poe->sender->ID,
            };

            $self->set_queued($wheel_id, [])
                if not $self->has_queued($wheel_id);
            push(@{ $self->get_queue($wheel_id) }, $queued);
        }
    }


=method return_to_sender(ProxyMessage :$message,WheelID :$wheel_id, SessionID :$return_session,Str :$return_event,Ref :$tag?) is Event

This method sends a message, and also stores context information related to the
message including where to send the result.

=cut

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
        
        if($self->has_wheel($wheel_id))
        {
            $self->get_wheel($wheel_id)->put($message);
        }
        else
        {
            my $queued = 
            {
                message => $message,
                sender  => $self->poe->sender->ID,
            };

            $self->set_queued($wheel_id, [])
                if not $self->has_queued($wheel_id);
            push(@{ $self->get_queue($wheel_id) }, $queued);
        }
    }
}
1;
__END__
=head1 DESCRIPTION

POEx::ProxySession::MessageSender is a utility role that both Client and Server
consume to provide common semantics to sending messages. 

