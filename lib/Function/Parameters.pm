package Function::Parameters;

use strict;
use warnings;

our $VERSION = '0.05';

use Carp qw(croak confess);
use Devel::Declare;
use B::Hooks::EndOfScope;

our @CARP_NOT = qw(Devel::Declare);


# Make our import chainable so a wrapper module that wants to turn on F:P
# for its users can just say
#    sub import { Function::Parameters->import; }
#
# To make that possible we skip all subs named 'import' in our search for the
# target package.
#
sub guess_caller {
	my ($start) = @_;
	$start ||= 1;

	my $defcaller = (caller $start)[0];
	my $caller = $defcaller;

	for (my $level = $start; ; ++$level) {
		my ($pkg, $function) = (caller $level)[0, 3] or last;
		$function =~ /::import\z/ or return $caller;
		$caller = $pkg;
	}
	$defcaller
}


# Parse import spec and make shit happen.
#
my @bare_arms = qw(function method);

sub import_into {
	my $victim = shift;

	@_ or @_ = ('fun', 'method');
	if (@_ == 1 && ref($_[0]) eq 'HASH') {
		@_ = map [$_, $_[0]{$_}], keys %{$_[0]}
			or return;
	}

	my %spec;

	my $bare = 0;
	for my $proto (@_) {
		my $item = ref $proto
			? $proto
			: [$proto, $bare_arms[$bare++] || confess(qq{Don't know what to do with "$proto"})]
		;
		my ($name, $type) = @$item;
		$name =~ /^[^\W\d]\w*\z/
			or confess qq{"$name" doesn't look like a valid identifier};
		my ($index) = grep $bare_arms[$_] eq $type, 0 .. $#bare_arms
			or confess qq{"$type" doesn't look like a valid type (one of ${\join ', ', @bare_arms})};
		
		$spec{$name} = {const => mk_parse($index)};
	}
	
	Devel::Declare->setup_for($victim, \%spec);
	for my $name (keys %spec) {
		no strict 'refs';
		*{$victim . '::' . $name} = \&_declarator;
	}
}

sub import {
	my $class = shift;
	my $caller = guess_caller;
	import_into $caller, @_;
}

sub _declarator {
	$_[0]
}


# Wrapper around substr where param 3 is an end offset, not a length.
#
sub _substring {
	@_ >= 4
	? substr $_[0], $_[1], $_[2] - $_[1], $_[3]
	: substr $_[0], $_[1], $_[2] - $_[1]
}

sub _skip_space {
	my ($ctx, $key) = @_;
	my $cur = my $start = $ctx->{offset};
	while (my $d = Devel::Declare::toke_skipspace $cur) {
		$cur += $d;
	}
	$ctx->{space}{$key} .= _substring Devel::Declare::get_linestr, $start, $cur if $key;
	$ctx->{offset} = $cur;
}

sub _grab_name {
	my ($ctx) = @_;
	my $p = $ctx->{offset};
	my $namlen = Devel::Declare::toke_scan_word $p, !!'handle_package'
		or return;
	my $str = Devel::Declare::get_linestr;
	$ctx->{name} = substr $str, $p, $namlen;
	$ctx->{offset} += $namlen;
	_skip_space $ctx, 'name';
}

sub _grab_params {
	my ($ctx) = @_;
	substr(Devel::Declare::get_linestr, $ctx->{offset}, 1) eq '('
		or return;
	$ctx->{offset}++;
	_skip_space $ctx, 'params';

	my $pcount = 0;

	LOOP: {
		my $c = substr Devel::Declare::get_linestr, $ctx->{offset}, 1;

		if ($c =~ /^[\$\@%]\z/) {
			$ctx->{offset}++;
			_skip_space $ctx, "params_$pcount";
			my $namlen = Devel::Declare::toke_scan_word $ctx->{offset}, !'handle_package'
				or croak "Missing identifier";
			my $name = substr Devel::Declare::get_linestr, $ctx->{offset}, $namlen;
			$ctx->{params} .= $c . $name . ',';
			$ctx->{offset} += $namlen;
			_skip_space $ctx, "params_$pcount";

			$c = substr Devel::Declare::get_linestr, $ctx->{offset}, 1;
			if ($c eq ',') {
				$ctx->{offset}++;
				_skip_space $ctx, "params_$pcount";
				$pcount++;
				redo LOOP;
			}
		}

		if ($c eq ')') {
			$ctx->{offset}++;
			_skip_space $ctx, 'params';
			return;
		}

		if ($c eq '') {
			croak "Unexpected EOF in parameter list";
		}

		croak "Unexpected '$c' in parameter list";
	}
}

sub _parse_parens {
	my ($ctx) = @_;

	my $strlen = Devel::Declare::toke_scan_str $ctx->{offset};
	$strlen == 0 || $strlen == -1 and return;

	$strlen < 0 and confess "Devel::Declare::toke_scan_str done fucked up ($strlen); see https://rt.cpan.org/Ticket/Display.html?id=51679";

	my $str = Devel::Declare::get_lex_stuff;
	Devel::Declare::clear_lex_stuff;

	$ctx->{offset} += $strlen;

	$str
}

sub _grab_proto {
	my ($ctx) = @_;

	my $savepos = $ctx->{offset};

	substr(Devel::Declare::get_linestr, $ctx->{offset}, 1) eq ':'
		or return;
	$ctx->{offset}++;
	_skip_space $ctx, 'proto_tmp';

	unless (substr(Devel::Declare::get_linestr, $ctx->{offset}, 1) eq '(') {
		$ctx->{offset} = $savepos;
		delete $ctx->{space}{proto_tmp};
		return;
	}
	$_->{proto} .= delete $_->{proto_tmp} for $ctx->{space};

	defined(my $str = _parse_parens $ctx)
		or croak "Malformed prototype";
	$ctx->{proto} = $str;

	_skip_space $ctx, 'proto';
}

sub _grab_attr {
	my ($ctx) = @_;

	my $pcount = 0;

	if (substr(Devel::Declare::get_linestr, $ctx->{offset}, 1) eq ':') {
		$ctx->{offset}++;
		_skip_space $ctx, "attr_$pcount";
	} elsif (!defined $ctx->{proto}) {
		return;
	}

	while () {
		my $namlen = Devel::Declare::toke_scan_word $ctx->{offset}, !'handle_package'
			or return;
		$ctx->{attr} .= substr Devel::Declare::get_linestr, $ctx->{offset}, $namlen;
		$ctx->{offset} += $namlen;
		_skip_space $ctx, "attr_$pcount";
		if (substr(Devel::Declare::get_linestr, $ctx->{offset}, 1) eq '(') {
			defined(my $str = _parse_parens $ctx)
				or croak "Malformed attribute argument list";
			$ctx->{attr} .= "($str)";
			_skip_space $ctx, "attr_$pcount";
		}
		$pcount++;

		if (substr(Devel::Declare::get_linestr, $ctx->{offset}, 1) eq ':') {
			$ctx->{offset}++;
			_skip_space $ctx, "attr_$pcount";
		}
	}
}

# IN:
#  fun name (params) :(proto) :attr { ... }
# OUT:
#  fun (do { sub                        (proto) :attr { self? my (params) = @_; ... } })
#  fun (do { sub name (proto); sub name (proto) :attr { self? my (params) = @_; ... } });
#
sub _generate {
	my ($ctx, $declarator, $implicit_self) = @_;

	my $gen = '(do{sub';

	my $skipped = join '', values %{$ctx->{space}};
	my $lines = $skipped =~ tr/\n//;
	$gen .= "\n" x $lines;

	my $proto = defined $ctx->{proto} ? "($ctx->{proto})" : '';

	my $is_stmt = 0;
	if (defined(my $name = $ctx->{name})) {
		$is_stmt = 1;
		$gen .= " $name$proto;";
		$gen .= "sub $name";
	}

	$gen .= $proto;

	if (defined $ctx->{attr}) {
		$gen .= ":$ctx->{attr}";
	}

	$gen .= '{';
	$gen .= "BEGIN{${\__PACKAGE__}::_fini($is_stmt)}";

	if ($implicit_self) {
		$gen .= 'my$self=shift;';
	}
	if (defined $ctx->{params}) {
		$gen .= "my($ctx->{params})=\@_;";
	}
	$gen
}

sub mk_parse {
	my ($implicit_self) = @_;

	sub {
		my ($declarator, $offset_orig) = @_;
		my $ctx = {
			offset => $offset_orig,
			space => {},
		};

		$ctx->{offset} += Devel::Declare::toke_move_past_token($ctx->{offset});
		_skip_space $ctx;

		my $start = $ctx->{offset};

		_grab_name $ctx;
		_grab_params $ctx;
		_grab_proto $ctx;
		_grab_attr $ctx;

		my $offset = $ctx->{offset};

		my $linestr = Devel::Declare::get_linestr;
		substr($linestr, $offset, 1) eq '{'
			or croak qq[I was expecting a function body, not "${\substr $linestr, $offset}"];

		my $gen = _generate $ctx, $declarator, $implicit_self;
		my $oldlen = $offset + 1 - $start;
		_substring $linestr, $start, $offset + 1, (' ' x $oldlen) . $gen;
		Devel::Declare::set_linestr $linestr;
	}
}

# Patch in the end of our synthetic 'do' block, close argument list, and
# optionally terminate the statement.
#
sub _fini {
	my ($stmt) = @_;
	on_scope_end {
		my $off = Devel::Declare::get_linestr_offset;
		my $str = Devel::Declare::get_linestr;
		substr $str, $off, 0, '})' . ($stmt ? ';' : '');
		Devel::Declare::set_linestr $str;
	};
}

'ok'

__END__

=head1 NAME

Function::Parameters - subroutine definitions with parameter lists

=head1 SYNOPSIS

 use Function::Parameters;
 
 fun foo($bar, $baz) {
   return $bar + $baz;
 }
 
 fun mymap($fun, @args) :(&@) {
   my @res;
   for (@args) {
     push @res, $fun->($_);
   }
   @res
 }
 
 print "$_\n" for mymap { $_ * 2 } 1 .. 4;
 
 method set_name($name) {
   $self->{name} = $name;
 }

=cut

=pod

 use Function::Parameters 'proc', 'meth';
 
 my $f = proc ($x) { $x * 2 };
 meth get_age() {
   return $self->{age};
 }

=head1 DESCRIPTION

This module lets you use parameter lists in your subroutines. Thanks to
L<Devel::Declare> it works without source filters.

WARNING: This is my first attempt at using L<Devel::Declare> and I have
almost no experience with perl's internals. So while this module might
appear to work, it could also conceivably make your programs segfault.
Consider this module alpha quality.

=head2 Basic stuff

To use this new functionality, you have to use C<fun> instead of C<sub> -
C<sub> continues to work as before. The syntax is almost the same as for
C<sub>, but after the subroutine name (or directly after C<fun> if you're
writing an anonymous sub) you can write a parameter list in parentheses. This
list consists of comma-separated variables.

The effect of C<fun foo($bar, $baz) {> is as if you'd written
C<sub foo { my ($bar, $baz) = @_; >, i.e. the parameter list is simply
copied into C<my> and initialized from L<@_|perlvar/"@_">.

In addition you can use C<method>, which understands the same syntax as C<fun>
but automatically creates a C<$self> variable for you. So by writing
C<method foo($bar, $baz) {> you get the same effect as
C<sub foo { my $self = shift; my ($bar, $baz) = @_; >.

=head2 Customizing the generated keywords

You can customize the names of the keywords injected in your package. To do that
you pass a hash reference in the import list:

 use Function::Parameters { proc => 'function', meth => 'method' }; # -or-
 use Function::Parameters { proc => 'function' }; # -or-
 use Function::Parameters { meth => 'method' };

The first line creates two keywords, C<proc> and C<meth> (for defining
functions and methods, respectively). The last two lines only create one
keyword. Generally the hash keys can be any identifiers you want while the
values have to be either C<function> or C<method>. The difference between
C<function> and C<method> is that C<method>s automatically
L<shift|perlfunc/shift> their first argument into C<$self>.

The following shortcuts are available:

 use Function::Parameters;
    # is equivalent to #
 use Function::Parameters { fun => 'function', method => 'method' };

=cut

=pod

 use Function::Parameters 'foo';
   # is equivalent to #
 use Function::Parameters { 'foo' => 'function' };

=cut

=pod

 use Function::Parameters 'foo', 'bar';
   # is equivalent to #
 use Function::Parameters { 'foo' => 'function', 'bar' => 'method' };

=head2 Other advanced stuff

Normally, Perl subroutines are not in scope in their own body, meaning the
parser doesn't know the name C<foo> or its prototype while processing
C<sub foo ($) { foo $bar[1], $bar[0]; }>, parsing it as
C<$bar-E<gt>foo([1], $bar[0])>. Yes. You can add parens to change the
interpretation of this code, but C<foo($bar[1], $bar[0])> will only trigger
a I<foo() called too early to check prototype> warning. This module attempts
to fix all of this by adding a subroutine declaration before the definition,
so the parser knows the name (and possibly prototype) while it processes the
body. Thus C<fun foo($x) :($) { $x }> really turns into
C<sub foo ($); sub foo ($) { my ($x) = @_; $x }>.

If you need L<subroutine attributes|perlsub/"Subroutine Attributes">, you can
put them after the parameter list with their usual syntax.

Syntactically, these new parameter lists live in the spot normally occupied
by L<prototypes|perlsub/"Prototypes">. However, you can include a prototype by
specifying it as the first attribute (this is syntactically unambiguous
because normal attributes have to start with a letter).

If you want to wrap C<Function::Parameters>, you may find C<import_into>
helpful. It lets you specify a target package for the syntax magic, as in:

  package Some::Wrapper;
  use Function::Parameters ();
  sub import {
    my $caller = caller;
    Function::Parameters::import_into $caller;
    # or Function::Parameters::import_into $caller, @other_import_args;
  }

C<import_into> is not exported by this module, so you have to use a fully
qualified name to call it.

=head1 AUTHOR

Lukas Mai, C<< <l.mai at web.de> >>

=head1 COPYRIGHT & LICENSE

Copyright 2010, 2011 Lukas Mai.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut
