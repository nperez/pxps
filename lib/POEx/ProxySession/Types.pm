package POEx::ProxySession::Types;
use warnings;
use strict;
use 5.010;

#ABSTRACT: Types for use within the ProxySession environment

use MooseX::Types -declare => ['ProxyMessage'];
use MooseX::Types::Moose(':all');
use MooseX::Types::Structured('Dict', 'Optional');

=head1 Types

=head2 ProxyMessage

ProxyMessage is a Dict with the following structure:

    type => Str,
    id => Int,
    payload => Optional[Str],
    to => Optional[Str],
    success => Optional[Bool],

type can be any of the following: deliver, result, subscribe, publish, listing,
and rescind. Each type has some light validation. Deliver requires 'to' to be
set. Result requires 'success' to be set. Subscribe requires 'to'. Publish and
rescind both require 'payload' to be set. 

This type does not validate the contents of the payload.

=cut

subtype ProxyMessage,
    as Dict
    [
        type => Str,
        id => Int,
        payload => Optional[Str],
        to => Optional[Str],
        success => Optional[Bool],
    ],
    where 
    {
        my $hash = $_;
        given($hash->{type})
        {
            when('deliver')
            {
                return defined($hash->{to});
            }
            when('result')
            {
                return defined($hash->{success});
            }
            when('subscribe')
            {
                return defined($hash->{to});
            }
            when('publish')
            {
                return defined($hash->{payload});
            }
            when('rescind')
            {
                return defined($hash->{payload});
            }
            when('listing')
            {
                return 1;
            }
            default
            {
                # we do this so that this may be used as a base type
                return 1;
            }
        }
    };
        
1;
__END__
=head1 DESCRIPTION

POEx::ProxySession::Types provides types for use within the ProxySession
environment that are self validating.

