package POEx::Role::ProxyEvent;

#ABSTRACT: Provide a decorator to label events to be proxied

use MooseX::Declare;

role POEx::Role::ProxyEvent with POEx::Role::Event
{
}
1;
__END__
=head1 DESCRIPTION

This role is merely a decorator for methods to indicate that the method should
be available for proxy.

