package Text::MacroScript;

require v5.10;

use strict;
use warnings;

use Carp qw( carp croak );
our @CARP_NOT = ( __PACKAGE__ );
use Path::Tiny;

use vars qw( $VERSION $WS_RE $NAME_RE $COMMENT );
$VERSION 	= '2.10_01'; 

BEGIN {
	$WS_RE 		= qr/ [\t\f\r ] /x;
	$NAME_RE 	= qr/ [^\s\[\|\]\#]+ /x;		# name cannot contain blanks [ | ] #
	$COMMENT	= "%%";							# comment macro
};

#------------------------------------------------------------------------------
# object to hold current input stack for nested structs
use enum qw( CTX_ARGS=1 CTX_TEXT );
{
	package # hide this from CPAN
		Text::MacroScript::Context;
	
	use Object::Tiny::RW
		'type',					# type of struct to match, one of CTX_...
		'start_line_nr',		# line number where struct started
		'commit_func',			# function to call when struct ends
								# passed $output_ref argument

		# collecting parameters
		'args',					# current collected arguments
		'open_parens',			# number of open parenthesis
	;
	
	sub new {
		my($class, $type, $start_line_nr, $commit_func) = @_;

		my $self = $class->SUPER::new(
			type			=> $type,
			start_line_nr	=> $start_line_nr,
			commit_func		=> $commit_func,
			
			args 			=> [],
			open_parens		=> 1,		# init at 1, as first '[' is already matched
		);
		return $self;
	}
}

#------------------------------------------------------------------------------
# main object
use Object::Tiny::RW 
	'parse_func',				# current parsing function
	
	'file',						# current input file name for error messages
	'line_nr',					# current line number
	
	'context',					# stack of Text::MacroScript::Context, empty if none
	'actions',					# hash of text -> function to call if matched
	'variables',				# hash of variable name -> current value
	'macros',					# hash of scripts/macros name -> body
	'is_script',				# TRUE for script, false for macro
	
	'args',						# list of arguments to script
	'regexp',					# big regexp computed each time text_action changes

	'embedded',					# true if parsing embedded text
	'in_embedded',				# true if inside embedded delimiters
	'opendelim',				# open delimiter for embedded processing
	'closedelim',				# close delimiter for embedded processing
	'comment',					# True to create the %%[] comment macro
	;

#------------------------------------------------------------------------------
# new
sub new {
    my($class, %opts) = @_;
	
	my $self = $class->SUPER::new(
		parse_func	=> \&_parse_execute,
		file	 	=> '-',
		line_nr		=> 1,
		
		context		=> [],
		actions		=> {},
		variables 	=> {},
		macros		=> {},
		is_script	=> {},

		args		=> [],
		regexp		=> qr//,
		
		embedded	=> 0,
		in_embedded	=> 0,
		opendelim	=> '<:',
		closedelim	=> ':>',
	);
	$self->_update_regexp;
	
	# parse options: -comment
	if ($opts{-comment}) {
        $self->_define_standard_comment;
		$self->comment(1);
	}
	delete $opts{-comment};
	
	# parse options: -embedded
	if ($opts{-embedded} || defined($opts{-opendelim})) {
		$self->embedded(1);
		$self->opendelim($opts{-opendelim} // "<:");
		$self->closedelim($opts{-closedelim} // $opts{-opendelim} // ":>");
	}
	delete @opts{qw( -embedded -opendelim -closedelim)};

	# parse options: -variable
	if ($opts{-variable}) {
		foreach (@{$opts{-variable}}) {
			my($name, $value) = @$_;
			$self->define_variable($name, $value);
		}
	}
	delete $opts{-variable};
	
	# parse options: -macro
	if ($opts{-macro}) {
		foreach (@{$opts{-macro}}) {
			my($name, $value) = @$_;
			$self->define_macro($name, $value);
		}
	}
	delete $opts{-macro};
	
	# parse options: -script
	if ($opts{-script}) {
		foreach (@{$opts{-script}}) {
			my($name, $value) = @$_;
			$self->define_script($name, $value);
		}
	}
	delete $opts{-script};
	
	# parse options: -file
	if ($opts{-file}) {
        foreach my $file (@{$opts{-file}}) {
            $self->load_file($file);
        }
	}
	delete $opts{-file};
	
	# check for invalid options
	croak "Invalid options ".join(",", sort keys %opts) if %opts;	
	
	return $self;
}

#------------------------------------------------------------------------------
# error
sub _error {
	my($self, $message) = @_;
	chomp($message);
	die "Error at file ", $self->file, " line ", $self->line_nr, ": ", $message, "\n";
}

#------------------------------------------------------------------------------
# contexts
sub _push_context {
	my($self, $type, $commit_func) = @_;
	
	my $previous_parse = $self->parse_func;
	my $context = Text::MacroScript::Context->new($type, $self->line_nr, 
				sub {
					my($output_ref) = @_;
					
					# pop context
					my $context = $self->_last_context_assert($type);
					my @args = @{$context->args};
					$self->_pop_context;
					
					# reset parser - it will be used when defining the variable
					$self->parse_func( $previous_parse );
					
					# call commit function with input arguments
					$commit_func->($output_ref, @args);
				});
	push @{$self->context}, $context;
}

sub _last_context {
	my($self) = @_;
	$self->_error("Unbalanced close structure") unless @{$self->context};
	return $self->context->[-1];
}

sub _last_context_assert {
	my($self, $type) = @_;
	my $context = $self->_last_context();
	$self->_error("Unbalanced close structure") unless $type == $context->type;
	return $context;
}

sub _pop_context {
	my($self) = @_;
	$self->_last_context();
	pop @{$self->context};
}

#------------------------------------------------------------------------------
# Destroy object, syntax error if input not complete - e.g. missing close struct
DESTROY {
	my($self) = @_;
	if (@{$self->context}) {
		my $context = $self->_last_context;
		$self->line_nr( $context->start_line_nr );
		$self->_error("Unbalanced open structure at end of file");
	}
}

#------------------------------------------------------------------------------
# create the parsing regexp
sub _update_regexp {
	my($self) = @_;
	my @actions_re;
	
	use re 'eval';

	# escape chars
	push @actions_re, qr/ (?> \\ ( [\#\%] ) 	(?{ \&_match_escape }) ) /mx;
	
	# escape newline
	push @actions_re, qr/ (?> \\ \n				(?{ \&_match_escape_newline }) ) /mx;
	
	# %DEFINE_VARIABLE
	push @actions_re, qr/ (?> ^ $WS_RE* \% DEFINE_VARIABLE
												(?{ \&_match_define_variable }) ) /mx;

	# %UNDEFINE_VARIABLE
	push @actions_re, qr/ (?> ^ $WS_RE* \% UNDEFINE_VARIABLE
												(?{ \&_match_undefine_variable }) ) /mx;

	# %DEFINE_SCRIPT
	push @actions_re, qr/ (?> ^ $WS_RE* \% DEFINE_SCRIPT
												(?{ \&_match_define_script }) ) /mx;
	
	# %UNDEFINE_SCRIPT
	push @actions_re, qr/ (?> ^ $WS_RE* \% UNDEFINE_SCRIPT
												(?{ \&_match_undefine_macro_script }) ) /mx;

	# %DEFINE
	push @actions_re, qr/ (?> ^ $WS_RE* \% DEFINE
												(?{ \&_match_define_macro }) ) /mx;
	
	# %UNDEFINE
	push @actions_re, qr/ (?> ^ $WS_RE* \% UNDEFINE
												(?{ \&_match_undefine_macro_script }) ) /mx;

	# %LOAD
	push @actions_re, qr/ (?> ^ $WS_RE* \% LOAD
												(?{ \&_match_load }) ) /mx;

	# %INCLUDE
	push @actions_re, qr/ (?> ^ $WS_RE* \% INCLUDE
												(?{ \&_match_include }) ) /mx;

	# concatenate operator
	push @actions_re, qr/ (?> $WS_RE* \# \# $WS_RE*
												(?{ \&_match_concat }) ) /mx;
	
	# arguments to scripts
	push @actions_re, qr/ (?> \# ( \d+ )		(?{ \&_match_expand_arg }) ) /mx;
	
	
	# user actions reverse sorted by length, so that longest match is found
	my $actions = $self->actions;
	for my $key (sort {length $b <=> length $a} keys %$actions)  {
		push @actions_re, qr{ (?> \Q$key\E (?{ \&_match_action }) ) }mx;
	}
	
	my $regexps = join(' | ', @actions_re);
	my $regexp = qr/ (?| $regexps )/mx;
	
	$self->regexp($regexp);
}

#------------------------------------------------------------------------------
# match functions: called with matched text and following text; return new
# following text
sub _match_escape {
	my($self, $output_ref, $match, $input) = @_;
	$$output_ref .= $1;			# special char is no longer parsed
	return $input;
}

sub _match_escape_newline {
	my($self, $output_ref, $match, $input) = @_;
	$$output_ref .= ' ';
	return $input;
}

sub _match_concat {
	my($self, $output_ref, $match, $input) = @_;
	return $input;
}

sub _match_define_variable {
	my($self, $output_ref, $match, $input) = @_;
	
	$input =~ / $WS_RE* ( $NAME_RE ) $WS_RE* \[ /x 
		or $self->_error("Expected NAME [EXPR]");
	my $name = $1;
	$input = $';
	
	# create a new context
	$self->_push_context(CTX_ARGS, 
			sub {
				my($output_ref, @args) = @_;
				@args == 1 or $self->_error("Only one argument expected");
				$self->define_variable($name, $args[0]);
			});
	
	# change parser
	$self->parse_func( \&_parse_args );
	
	return $input;
}

sub _match_undefine {
	my($self, $input_ref) = @_;
	
	$$input_ref =~ / $WS_RE* ( $NAME_RE ) $WS_RE* /x 
		or $self->_error("Expected NAME");
	my $name = $1;
	$$input_ref = $';
	
	return $name;
}

sub _match_undefine_variable {
	my($self, $output_ref, $match, $input) = @_;

	my $name = $self->_match_undefine( \$input );
	$self->undefine_variable($name);

	return $input;
}

sub _match_define_macro_script {
	my($self, $output_ref, $match, $input, $is_script) = @_;
	
	# collect name
	$input =~ / $WS_RE* ( $NAME_RE ) $WS_RE* /x 
		or $self->_error("Expected NAME");
	my $name = $1;
	$input = $';
	
	# definition in the same line?
	if ($input =~ /^ \[ /x) {
		$input = $';
		
		# create a new context
		$self->_push_context(CTX_ARGS, 
				sub {
					my($output_ref, @args) = @_;
					@args == 1 or $self->_error("Only one argument expected");
					$self->_define_macro_script($name, $args[0], $is_script);
				});
		
		# change parser
		$self->parse_func( \&_parse_args );
	}
	else {
		$input =~ s/^\s+//;		# eat newline

		# collect text up to %END_DEFINE
		$self->_push_context(CTX_TEXT, 
				sub {
					my($output_ref, $text) = @_;
					$self->_define_macro_script($name, $text, $is_script);
				});
		
		# change parser
		$self->parse_func( \&_parse_collect_text );
	}		

	return $input;
}

sub _match_define_macro {
	my($self, $output_ref, $match, $input) = @_;
	return $self->_match_define_macro_script($output_ref, $match, $input, 0);
}

sub _match_filename {
	my($self, $input, $func) = @_;
	
	$input =~ / $WS_RE* \[ /x 
		or $self->_error("Expected [FILENAME]");
	$input = $';
	
	# create a new context
	$self->_push_context(CTX_ARGS, 
			sub {
				my($rt_output_ref, @args) = @_;
				@args == 1 or $self->_error("Only one argument expected");
				$self->$func($rt_output_ref, $args[0]);
			});
	
	# change parser
	$self->parse_func( \&_parse_args );
	
	return $input;
}

sub _match_load {
	my($self, $output_ref, $match, $input) = @_;
	return $self->_match_filename($input, \&_load_file);
}

sub _match_include {
	my($self, $output_ref, $match, $input) = @_;
	return $self->_match_filename($input, \&_expand_file);
}

sub _match_define_script {
	my($self, $output_ref, $match, $input) = @_;
	return $self->_match_define_macro_script($output_ref, $match, $input, 1);
}

sub _match_undefine_macro_script {
	my($self, $output_ref, $match, $input) = @_;
	
	my $name = $self->_match_undefine( \$input );
	$self->_undefine_macro_script($name);

	return $input;
}

sub _match_action {
	my($self, $output_ref, $match, $input) = @_;

	my $func = $self->actions->{$match} 
		or $self->_error("No action found for '$match'");
	return $func->($self, $output_ref, $match, $input);
}

sub _match_expand_arg {
	my($self, $output_ref, $match, $input) = @_;
	
	my $arg = $1;
	($arg < scalar(@{ $self->args }))
		or $self->_error("Missing parameters");
	
	$$output_ref .= $self->_expand( $self->args->[$arg] );
	return  $input;
}

#------------------------------------------------------------------------------
# match engine - recurse to expand all macros, return expanded text
sub _expand {
	my($self, $input) = @_;
	$input //= '';
	my $output = '';

	while ($input ne '') {
		$input = $self->parse_func->($self, \$output, $input);
	}
	return $output;
}

# expand embedded text
sub _expand_embedded {
	my($self, $input) = @_;
	$input //= '';
	my $output = '';

	while ($input ne '') {
		if ($self->in_embedded) {
			my $closedelim = $self->closedelim;
			if ($input =~ /\Q$closedelim\E/) {
				$input = $';
				$output .= $self->_expand($`);
				$self->in_embedded(0);
			}
			else {
				$output .= $self->_expand($input);
				$input = '';
			}
		}
		else {
			my $opendelim = $self->opendelim;
			if ($input =~ /\Q$opendelim\E/) {
				$output .= $`;
				$input = $';
				$self->in_embedded(1);
			}
			else {
				$output .= $input;
				$input = '';
			}
		}
	}
	return $output;
}

#------------------------------------------------------------------------------
# choose either _expand or _expand_embedded
sub expand {
	my($self, $text, $file, $line_nr) = @_;
    defined($file) and $self->file($file);
    $line_nr       and $self->line_nr($line_nr);

	if ($self->embedded) {
		return $self->_expand_embedded($text);
	}
	else {
		return $self->_expand($text);
	}
}



# parse functions: execute macros
# input: text to parse and current output; 
# output: remaining text to parse and total text to output 
sub _parse_execute {
	my($self, $output_ref, $input) = @_;
	
	if ($input =~ / $self->{regexp} /x) {
		my $action = $^R;
		
		# execute action and set new input
		$$output_ref .= $`;
		$input = $self->$action($output_ref, $&, $');	
	}
	else {
		$$output_ref .= $input;					# remaining input
		$input = '';
	}
	
	return $input;
}

# parse functions: collect macro arguments
sub _parse_args {
	my($self, $output_ref, $input) = @_;
	
	use re 'eval';
	
	my $context = $self->_last_context_assert(CTX_ARGS);
	while ( $context->open_parens > 0 && $input ne '' ) {
		if ( $input =~ /
				(.*?)
				(?| (?> \\ ( [\[\]\|] ) 	(?{ \&_parse_args_escape }) )
				  | (?> ( \[ )				(?{ \&_parse_args_open }) )
				  | (?> ( \| )				(?{ \&_parse_args_separator }) )
				  | (?> ( \] )				(?{ \&_parse_args_close }) )
				) 
				/sx ) {
			my $action = $^R;
			$input = $';			# unparsed input
			$action->($context);			
		}
		else {
			@{ $context->args } or push @{ $context->args }, '';
			$context->args->[-1] .= $input;
			$input = '';
		}
	}
	
	# check for end of parsing
	if ( $context->open_parens == 0 ) {
		$context->commit_func->($output_ref);
	}
	
	return $input;
}

sub _parse_args_escape {
	my($context) = @_;
	@{ $context->args } or push @{ $context->args }, '';
	$context->args->[-1] .= $1.$2; 
}

sub _parse_args_open {
	my($context) = @_;
	@{ $context->args } or push @{ $context->args }, '';
	$context->args->[-1] .= $1.$2;
	$context->{open_parens}++; 
}

sub _parse_args_separator {
	my($context) = @_;
	@{ $context->args } or push @{ $context->args }, '';
	if ( $context->open_parens == 1 ) {
		$context->args->[-1] .= $1;
		push @{$context->args}, ''; 
	}
	else {
		$context->args->[-1] .= $1.$2;
	}										
}

sub _parse_args_close {
	my($context) = @_;
	@{ $context->args } or push @{ $context->args }, '';
	if ( $context->open_parens == 1 ) {
		$context->args->[-1] .= $1;
	}
	else {
		$context->args->[-1] .= $1.$2;
	}
	$context->{open_parens}--;
}

# Collect definition in text
sub _parse_collect_text {
	my($self, $output_ref, $input) = @_;
	
	my $context = $self->_last_context_assert(CTX_TEXT);
	@{ $context->args } or push @{ $context->args }, '';
	if ($input =~ / ^ $WS_RE* \% END_DEFINE $WS_RE* /mx) {
		$context->args->[-1] .= $`;
		$input = $';
		$context->commit_func->($output_ref);
	}
	else {
		$context->args->[-1] .= $input;
		$input = '';
	}

	return $input;
}

#------------------------------------------------------------------------------
# Define a new variable or overwrite an existing one
sub define_variable {
	my($self, $name, $value) = @_;

	# setup for a possible recursive _expand(), if definition refers to itself
	# e.g. %DEFINE_VARIABLE X [#X + 1]
	$self->variables->{$name} //= '';		# default previous value
	$self->actions->{'#'.$name} = \&_expand_variable;
	$self->_update_regexp;

	$self->variables->{$name} = $self->_eval_expression($value);
}

sub _expand_variable {
	my($self, $output_ref, $match, $input) = @_;
	my $name = substr($match, 1);	# skip '#'
	$$output_ref .= $self->_expand( $self->variables->{$name} );
	return $input;
};

sub _eval_expression {
	my($self, $expression) = @_;
	
	# expand any macro calls in the expression
	my $value = $self->_expand($expression);
	
	# try to eval as a perl expression, drop value on failure
	{ 
		no warnings;
		my $eval_result = eval $value;
		if (! $@) {
			$value = $eval_result;
		}
	}
	return $value;
}
	
#------------------------------------------------------------------------------
# Undefine a variable; does nothing if variable does not exist
sub undefine_variable {
	my($self, $name) = @_;
	
	if (exists $self->variables->{$name}) {
		delete $self->variables->{$name};
		delete $self->actions->{'#'.$name};
		$self->_update_regexp;
	}
}

#------------------------------------------------------------------------------
# Define a new script/macro or overwrite an existing one
sub _define_macro_script {
	my($self, $name, $body, $is_script) = @_;

	$self->macros->{$name} = $body;
	$self->is_script->{$name} = $is_script;
	
	$self->actions->{$name.'['} = \&_macro_script_collect_args;
	$self->actions->{$name}     = \&_macro_script_no_args;
	$self->_update_regexp;
}

sub _macro_script_collect_args {
	my($self, $output_ref, $match, $input) = @_;

	my $name = substr($match, 0, length($match) - 1 );	# remove '['
	
	# create a new context
	$self->_push_context(CTX_ARGS, 
			sub {
				my($rt_output_ref, @args) = @_;
				$self->_expand_macro_script($name, \@args, $rt_output_ref);
			});
	
	# change parser
	$self->parse_func( \&_parse_args );
	
	return $input;
}

sub _macro_script_no_args {
	my($self, $output_ref, $match, $input) = @_;

	my @args;
	$self->_expand_macro_script($match, \@args, $output_ref);

	return $input;
}

sub _expand_macro_script {
	my($self, $name, $args, $output_ref) = @_;
	my @save_args = @{ $self->args };
	my @Param = @$args;					# to be used in script body
	my %Var = %{ $self->variables };	# to be used in script body
	$self->args( $args );				# set arguments for this call
	
	my $expanded_body = $self->_expand( $self->macros->{$name} );
	
	if ($self->is_script->{$name}) {
		my $evaled_body = eval $expanded_body;
		$self->_error("Eval error: $@") if $@;

		%{ $self->variables } = %Var;		# update any changed variables
		
		$$output_ref .= $evaled_body;
	}
	else {
		$$output_ref .= $expanded_body;
	}
	
	$self->args( \@save_args );			# restore previous level args
}

#------------------------------------------------------------------------------
# Undefine a script/macro; does nothing if script/macro does not exist
sub _undefine_macro_script {
	my($self, $name) = @_;
	
	if (exists $self->macros->{$name}) {
	
		delete $self->macros->{$name};
		delete $self->is_script->{$name};
		
		delete $self->actions->{$name.'['};
		delete $self->actions->{$name};
		
		$self->_update_regexp;
	}
}

#------------------------------------------------------------------------------
# load macro definitions from a file
sub _load_file {
    my($self, $output_ref, $file) = @_;

    # Treat loaded files as if wrapped in delimiters (only affects embedded
    # processing).
    my $in_embedded = $self->in_embedded; 
    $self->in_embedded(1); 

    $self->_expand_file(undef, $file);		# never output

    $self->in_embedded($in_embedded); 
}

sub load_file {
    my($self, $file) = @_;
	$self->_load_file(undef, $file);
}

#------------------------------------------------------------------------------
# parses the given file with expand() 
# Usage: $macro->expand_file($filename)
# In an array context will return the file, e.g.
# @expanded = $macro->expand_file($filename);
# In a void context will print to the current output filehandle
sub _expand_file {
    my($self, $output_ref, $file) = @_;

	# let Path::Tiny handle '~' processing
	$file or croak "Missing filename";
	$file = path($file);
	
	open(my $fh, $file) or $self->_error("Open '$file' failed: $!");
	my $line_nr;
	
	# define function to collect output
	my $output;
	if (! defined($output_ref)) {		
		$output = sub {}; 
	}
	elsif (ref($output_ref) eq 'SCALAR') {
		$output = sub { $$output_ref .= $_[0]; };
	}
	elsif (ref($output_ref) eq 'ARRAY') {
		$output = sub { push @$output_ref, $_[0]; };
	}
	elsif (ref($output_ref) eq 'GLOB') {
		$output = sub { print $_[0]; };
	}
	else {
		croak("invalid output_ref");
	}
	
	# read input
	while(defined(my $line = <$fh>)) {
		$line_nr++;
		$line = $self->expand($line, $file, $line_nr);
		
		$output->($line) if $line ne '';
	}

	close($fh) or croak "Close '$file' failed: $!";
}

sub expand_file {
    my($self, $file) = @_;
	my @lines;
	
	# build output destination
	my $output_ref = wantarray ? \@lines : \*STDOUT;
	$self->_expand_file($output_ref, $file);
	return @lines if wantarray;
}	

#------------------------------------------------------------------------------
# Wrappers for script/macro
sub define_macro {
	my($self, $name, $body) = @_;
	$self->_define_macro_script($name, $body, 0);
}

sub define_script {
	my($self, $name, $body) = @_;
	$self->_define_macro_script($name, $body, 1);
}

*undefine_macro  = \&_undefine_macro_script;
*undefine_script = \&_undefine_macro_script;

#------------------------------------------------------------------------------
# define the standard %% comment macro
sub _define_standard_comment {
    my($self) = @_;
    $self->define_macro($COMMENT, '');
}

#------------------------------------------------------------------------------
# deprecated method to define -macro, -script or -variable
sub define {
    my($self, $which, $name, $body) = @_;

	if ($which eq '-variable') {
		$self->define_variable($name, $body);
	}
	elsif ($which eq '-macro') {
		$self->define_macro($name, $body);
	}
	elsif ($which eq '-script') {
		$self->define_script($name, $body);
	}
	else {
		croak "$which method not supported";
	}
}

sub undefine {
    my($self, $which, $name) = @_;

	if ($which eq '-variable') {
		$self->undefine_variable($name);
	}
	elsif ($which eq '-macro') {
		$self->undefine_macro($name);
	}
	elsif ($which eq '-script') {
		$self->undefine_script($name);
	}
	else {
		croak "$which method not supported";
	}
}

1;

__END__

	
    # State temporaries used during processing
	'in_case',			# Are we in a %CASE block? 0, 'SKIP' or 1.
	;

### Public methods

#------------------------------------------------------------------------------
# deprecated method to list all -macro, -script or -variable
sub list { # Object method.
    my( $self, $which, $namesonly ) = @_;

    my @lines;
    local $_;

    $which     = uc substr( $which, 1 );
    my $script = '';
    $script    = "_$which" unless $which eq 'MACRO';

    my $array;

    if( $which eq 'VARIABLE' ) {
        $array = [ map { [ $_, $self->VARIABLE->{$_} ] } 
                    sort keys %{$self->VARIABLE} ];
    }
    else {
        $array = $self->{$which};
    }

    foreach( @{$array} ) {
        my( $name, $body ) = @{$_};
        my $line = "%DEFINE$script $name";

        if( $body =~ /\n/o ) {
            $line .= "\n$body%END_DEFINE\n" unless $namesonly;
        }
        else {
            $line .= " [$body]\n" unless $namesonly;
        }

        if( wantarray ) {
            push @lines, $line;
        }
        else {
            print "$line\n";
        }
    }

    @lines if wantarray;
}


#------------------------------------------------------------------------------
# deprecated method to undefine all -macro, -script or -variable
sub undefine_all { # Object method.
    my( $self, $which ) = @_;

    $which = uc substr( $which, 1 );

    if( $which eq 'VARIABLE' ) {
        %{$self->{$which}} = ();
    }
    else {
        @{$self->{$which}} = ();
    }

	# redefine comment macro
	$self->_define_standard_comment if $self->comment;
}


#------------------------------------------------------------------------------
# List all the macros to STDOUT or return to array, option -nameonly to list 
# only name
sub list_macro {
	my($self, $namesonly) = @_;
	$self->list(-macro, $namesonly);
}


#------------------------------------------------------------------------------
# Undefine all macros
sub undefine_all_macro {
	my($self) = @_;
	$self->undefine_all(-macro);
}


#------------------------------------------------------------------------------
# List all the scripts to STDOUT or return to array, option -nameonly to list 
# only name
sub list_script {
	my($self, $namesonly) = @_;
	$self->list(-script, $namesonly);
}


#------------------------------------------------------------------------------
# Undefine all scripts
sub undefine_all_script {
	my($self) = @_;
	$self->undefine_all(-script);
}


#------------------------------------------------------------------------------
# List all the variables to STDOUT or return to array, option -nameonly to list 
# only name
sub list_variable {
	my($self, $namesonly) = @_;
	$self->list(-variable, $namesonly);
}


#------------------------------------------------------------------------------
# Undefine all variables
sub undefine_all_variable {
	my($self) = @_;
	$self->undefine_all(-variable);
}


#------------------------------------------------------------------------------
# similar to _expand(), but only expands text between the open and close delimiters
sub _expand_embedded { # Object method.
	my($self, $text, $file, $line_nr) = @_;
    local $_ = $text;

    my $line = '';

    if( ! $self->in_embedded && /^$self->{opendelim}$/o ) {
        $self->in_embedded(1);
    } 
    elsif( $self->in_embedded && /^$self->{closedelim}$/o ) {
        $self->in_embedded(0);
    }
    elsif( ! $self->in_embedded ) {
        my $pos = index( $_, $self->opendelim );
        if( $pos > -1 ) {
            $line = substr( $_, 0, $pos ) if $pos > 0;
            my $start = $pos + length($self->opendelim);
            my $end   = index( $_, $self->closedelim, $start );
            if( $end > -1 ) {
                $line .= $self->_expand( 
									substr( $_, $start, $end - $start ), 
									$file, $line_nr );
                $line .= $self->_expand_embedded( 
									substr( $_, $end + length($self->closedelim) ), 
									$file, $line_nr );
            }
            else {
                $line .= $self->_expand( substr( $_, $start ), $file, $line_nr );
                $self->in_embedded(1);
            }
        }
        else {
            $line = $_;
        }
    }
    else {
        my $end = index( $_, $self->closedelim );
        if( $end > -1 ) {
            $line = $self->_expand( 
								substr( $_, 0, $end ), 
								$file, $line_nr );
            $self->in_embedded(0);
            $line .= $self->_expand_embedded( 
								substr( $_, $end + length($self->closedelim) ), 
								$file, $line_nr );
        }
        else {
            $line = $self->_expand( $_, $file, $line_nr );
        }
    }

    $line;
}


#------------------------------------------------------------------------------
# parse and expand passed string; file and line_nr are used for error messages
sub _expand { # Object method.
	my($self, $text, $file, $line_nr) = @_;
    local $_ = $text;
	
    my $where = "at $file line ".$self->line_nr;
	my $where_to = "from $file line ".$self->line_nr." to line $line_nr";
	
	if( /^\%((?:END_)?CASE)(?:\s*\[(.*?)\])?/mso || 
		( ($self->in_case || '') eq 'SKIP' ) ) {

		croak "Runaway \%DEFINE $where_to" if $self->in_macro;
		croak "Runaway \%DEFINE_SCRIPT $where_to" if $self->in_script;

		if( defined $1 and $1 eq 'CASE' ) {
			croak "Missing \%CASE condition $where" unless defined $2;

			my $eval    = $self->_expand_variable( $2 );
			my $result;
			eval {
				my %Var = %{$self->VARIABLE};
				local $_;
				$result = eval $eval;
				%{$self->VARIABLE} = %Var;
			};
			croak "Evaluation of %CASE [$eval] failed $where: $@" if $@;

			$self->in_case($result ? 1 : 'SKIP');
		}
		elsif( defined $1 and $1 eq 'END_CASE' ) {
			$self->in_case(0);
		}

		$_ = '';
	}
	elsif( ( $self->in_macro || $self->in_script ) && /^\%END_DEFINE/mso ) {
		# End of a multi-line macro or script
		$self->cur_define( $self->_expand_variable( $self->cur_define ) );

		if ($self->in_macro) {
			$self->in_macro(0);
			$self->_insert_element('MACRO', $self->cur_name, $self->cur_define );
		}
		else {
			$self->in_script(0);
			$self->_insert_element('SCRIPT', $self->cur_name, $self->cur_define );
		}

		$self->cur_name('');
		$self->cur_define('');
		
		$_ = '';
	}
	elsif( $self->in_macro || $self->in_script ) {
		# Accumulating the body of a multi-line macro or script
		my $which = $self->in_macro ? 'DEFINE' : 'DEFINE_SCRIPT';
		croak "Runaway \%$which $where_to"
		if /^\%
			(?:(?:UNDEFINE(?:_ALL)?|DEFINE)(?:_SCRIPT|_VARIABLE)?) |
			LOAD | INCLUDE | (?:END_)CASE
		   /msox;

		$self->{cur_define} .= $_;

		$_ = '';
	}
	elsif( /^\%UNDEFINE(?:_(SCRIPT|VARIABLE))?\s+([^][\s]+)/mso ) {
		# Undefining a macro, script or variable
		my $which = $1 || 'MACRO';

		carp "Cannot undefine non-existent $which $2 $where" 
		unless $self->_remove_element( $which, $2 ); 
 
		$_ = '';
	}
	elsif( /^\%UNDEFINE_ALL(?:_(SCRIPT|VARIABLE))?/mso ) {
		# Undefining all macros or scripts
		my $which = "-".lc($1 || 'MACRO');
		$self->undefine_all($which);

		$_ = '';
	}
	elsif( /^\%DEFINE(?:_(SCRIPT|VARIABLE))?\s+([^][\s]+)\s*\[(.*?)\]/mso ) {
		# Defining a single-line macro, script or variable
		my $which = $1 || 'MACRO';

		$self->_insert_element( $which, $2, $self->_expand_variable( $3 || '' ) );

		$_ = '';
	}
	elsif( /^\%DEFINE(?:_(SCRIPT))?\s+([^][\s]+)/mso ) {
		# Preparing to define a multi-line macro or script (we don't permit
		# multi-line variables)
		$self->cur_name($2);
		$self->cur_define('');
		if (defined $1) {
			$self->in_script(1);
		}
		else {
			$self->in_macro(1);
		}

		$_ = '';
	}
	elsif( /^\%(LOAD|INCLUDE)\s*\[(.+?)\]/mso ) {
		# Save state in local stack frame (i.e. recursion is taking care of
		# stacking for us)
		my $in_macro    = $self->in_macro;   # Should never be true
		my $in_script   = $self->in_script;  # Should never be true
		my $in_case     = $self->in_case;    # Should never be true
		my $in_embedded = $self->in_embedded;
		my $name        = $self->cur_name;
		my $define      = $self->cur_define;
		my $line_nr     = $self->line_nr;

		my @lines = ();
		
		# Load in new stuff
		if( $1 eq 'LOAD' ) {
			# If we are doing embedded processing and we are loading a new
			# file then we assume we are still in the embedded text since
			# we're loading macros, scripts etc.
			carp "Should be embedded when LOADing $2" 
			if ($self->embedded && ! $self->in_embedded);

			# $self->in_embedded(1); Should be 1 anyway - this is done

			# inside load_file().
			# This is a macro/scripts file; instantiates macros and scripts,
			# ignores everything else.
			$self->load_file( $2 );
		}
		else {
			# If we are doing embedded processing and we are including a new file
			# then we assume that we are not in embedded text at the start of that
			# file, i.e. we look freshly for an opening delimiter. 
			carp "Should be embedded when INCLUDINGing $2" 
			if ($self->embedded && ! $self->in_embedded);

			$self->in_embedded(0); # Should be 1, but we want it off now. 

			# This is a normal file that may contain macros/scripts - the
			# macros and scripts are instantiated and any text is returned
			# with all expansions applied
			@lines = $self->expand_file( $2 );
		}
	
		# Restore state
		$self->in_macro($in_macro);
		$self->in_script($in_script);
		$self->in_case($in_case);
		$self->in_embedded($in_embedded);
		$self->cur_name($name);
		$self->cur_define($define);
		$self->line_nr($line_nr);

		# Replace string with the outcome of the load (empty) or include 
		$_ = join '', @lines;
	}
	elsif( /^\%REQUIRE\s*\[(.+?)\]/mso ) {
		my $file = $1;
		eval {
			require $file;
		};
		carp "Failed to require $file: $@" if $@;

		$_ = '';
	}
	else {
		# This array is already ordered by length then by ASCII.
		foreach my $script ( @{$self->SCRIPT} ) {
			my( $name, $orig_body ) = @{$script};
			# We substitute wherever found, including in the middle of 'words'
			# or whatever (but we can always create macro names like *MYMACRO
			# which are unlikely to occur in words). 
			# Macro names shouldn't include ] and can't include [.
			s{
				\Q$name\E
				(?:\[(.+?)\])?  
			 }{
				# Get any parameters
				my @param = split /\|/, $1 if defined $1;
				# We get $body fresh every time since we could have the same
				# macro or script occur more than once in a line but of course
				# with different parameters.
				my $body  = $orig_body;
				# Substitute any parameters in the script's body; we go from
				# largest index to smallest to ensure that we substitute #13
				# before #1!
				if( $body =~ /#\d/mso ) {

					$body =~ s/\\#/\x0/msgo; # Hide escaped #s

					# Warnings don't seem to work correctly here so we switch
					# them off and do them manually.
					local $^W = 0;

					for( my $i = $#param; $i >= 0; $i-- ) {
						$body =~ s/#$i/$param[$i]/msg;
					}
					carp "Missing parameter or unescaped # in SCRIPT " .
						 "$name $body $where"
					if ( $#param > 9 and $body =~ /#\d\d\D/mso ) or 
									   ( $body =~ /#\d\D/mso );

					$body =~ s/\x0/#/msgo; # Unhide escaped #s
					# Extra parameters, i.e. those given in the text but not
					# used by the macro or script are ignored and do not
					# appear in the output.
				}
				# Evaluate the script 
				my $result = '';
				eval {
					my @Param = @param; # Give (local)  access to params
					my %Var   = %{$self->VARIABLE};
					local $_;
					$result   = eval $body;
					%{$self->VARIABLE} = %Var;
				};
				croak "Evaluation of SCRIPT $name failed $where: $@" 
				if $@;
				# This carp does't work - its supposed to catch a failed eval
				# and give an error message - instead perl doesn't set $@ but
				# outputs its own error message immediately instead. Although
				# we can switch off perl's message using local $^W = 0, doing
				# so means that the error goes by silently, so I've left the
				# default behaviour so at least we know we've got an error.
				# Please let me know how to fix this!

				# Return the result of the evaluation as the replacement string
				$result;
			 }gmsex; 
		}

		foreach my $macro ( @{$self->MACRO} ) {
			my( $name, $body ) = @{$macro};

			s{
				\Q$name\E
				(?:\[(.+?)\])?  
			 }{
				my @param = split /\|/, $1 if defined $1;
				{
					$body =~ s/\\#/\x0/msgo; # Hide escaped #s

					local $^W = 0;

					for( my $i = $#param; $i >= 0; $i-- ) {
						$body =~ s/#$i/$param[$i]/msg;
					}

					carp "Missing parameter or unescaped # in MACRO " .
						 "$name $body $where"
					if ( $#param > 9 and $body =~ /#\d\d\D/mso ) or 
									   ( $body =~ /#\d\D/mso );

					$body =~ s/\x0/#/msgo; # Unhide escaped #s
				}
				$body;
			 }gmsex; 
		}
	}

    $_;
}

1;

__END__

=head1 NAME

Text::MacroScript - A macro pre-processor with embedded perl capability 

=head1 SYNOPSIS

    use Text::MacroScript;

    # new() for macro processing

    my $Macro = Text::MacroScript->new;
    while( <> ) {
        print $Macro->expand( $_ ) if $_;
    }

    # Canonical use (the filename and line number improves error messages):
    my $Macro = Text::MacroScript->new;
    while( <> ) {
        print $Macro->expand( $_, $ARGV, $. ) if $_;
    }

    # new() for embedded macro processing

    my $Macro = Text::MacroScript->new( -embedded => 1 ); 
    # Delimiters default to <: and :>
    # or
    my $Macro = Text::MacroScript->new( -opendelim => '[[', -closedelim => ']]' );
    while( <> ) {
        print $Macro->expand( $_, $ARGV, $. ) if $_;
    }

    # Create a macro object and create initial macros/scripts from the file(s)
    # given:
    my $Macro = Text::MacroScript->new( 
                    -file => [ 'local.macro', '~/.macro/global.macro' ] 
                    );

    # Create a macro object and create initial macros/scripts from the
    # definition(s) given:
    my $Macro = Text::MacroScript->new(
                    -macro => [
                            [ 'MAX_INT' => '32767' ],
                        ],
                    -script => [
                        [ 'DHM2S' => 
                            [ 
                                my $s = (#0*24*60*60)+(#1*60*60)+(#2*60);
                                "#0 days, #1 hrs, #2 mins = $s secs" 
                            ],
                        ],
                    -variable => [ '*MARKER*' => 0 ],
                    );

    # We may of course use any combination of the options. 

    my $Macro = Text::MacroScript->new( -comment => 1 ); # Create the %%[] macro.

    # define()
    $Macro->define_macro( $macroname, $macrobody );
    $Macro->define_script( $scriptname, $scriptbody );
    $Macro->define_variable( $variablename, $variablebody );

    # undefine()
    $Macro->undefine_macro( $macroname );
    $Macro->undefine_script( $scriptname );
    $Macro->undefine_variable( $variablename );

    # undefine_all()
    $Macro->undefine( -macro );
    $Macro->undefine( -script );
    $Macro->undefine( -variable );

    # list()

    @macros    = $Macro->list( -macro );
    @macros    = $Macro->list( -macro, -namesonly );

    @scripts   = $Macro->list( -script );
    @scripts   = $Macro->list( -script, -namesonly );

    @variables = $Macro->list( -variable );
    @variables = $Macro->list( -variable, -namesonly );

    # load_file() - always treats the contents as within delimiters if we are
    # doing embedded processing.

    $Macro->load_file( $filename );

    # expand_file() - calls expand() for each input line.
    $Macro->expand_file( $filename );
    @expanded = $Macro->expand_file( $filename );
    
    # expand()
    $expanded = $Macro->expand( $unexpanded );
    $expanded = $Macro->expand( $unexpanded, $filename, $line_nr );

This bundle also includes the C<macropp> and C<macrodir> scripts which allows us
to expand macros without having to use/understand C<Text::MacroScript>,
although you will have to learn the handful of macro commands available and
which are documented here and in C<macropp>. C<macropp> provides more
documentation on the embedded approach.

The C<macroutil.pl> library supplied provides some functions which you may
choose to use in HTML work for example.

=head1 MACRO SYSTEMS VS EMBEDDED SYSTEMS

Macro systems read all the text, substituting anything which matches a macro
name with the macro's body (or script name with the result of the execution of
the script). This makes macro systems slower (they have to check for
macro/script names everywhere, not just in a delimited section) and more risky
(if we choose a macro/script name that normally occurs in the text we'll end
up with a mess) than embedded systems. On the other hand because they work on
the whole text not just delimited bits, macro systems can perform processing
that embedded systems can't. Macro systems are used extensively, for example
the CPP, C pre-processor, with its #DEFINE's, etc. 

Essentially, embedded systems print all text until they hit an opening 
delimiter. They then execute any code up until the closing delimiter. The text
that results replaces everything between and including the delimeters. They
then carry on printing text until they hit an opening delimeter and so on
until they've finished processing all the text. This module now provides both
approaches. 

=head1 DESCRIPTION

Define macros, scripts and variables in macro files or directly in text files. 

Commands can appear in separate macro files which are loaded in either via the
text files they process (e.g. via the L</%LOAD> command), or can be embedded
directly in text files. Almost every command that can appear in a file has an
equivalent object method so that programmers can achieve the same things in
code as can be achieved by macro commands in texts; there are also additional
methods which have no command equivalents. 

Most the examples given here use the macro approach. However this module now
directly supports an embedded approach and this is now documented. Although
you can specify your own delimiters where shown in examples we use the default
delimiters of C<E<lt>:> and C<:E<gt>> throughout.

=head2 Public methods

=head3 new

  $self = Text::MacroScript->new();
  $self = Text::MacroScript->new( %opts );

Create a new C<Text::MacroScript> object, initialized with the supplied 
options. By default creates an object for macro processing. 

For macro processing:

  my $Macro = Text::MacroScript->new;

For embedded macro processing:

  my $Macro = Text::MacroScript->new( -embedded => 1 ); 
  # Delimiters default to <: and :>

Or specify your own delimiters:
    
  my $Macro = Text::MacroScript->new( -opendelim => '[[', -closedelim => ']]' );

Or specify one delimiter to use for both (probably not wise):

  my $Macro = Text::MacroScript->new( -opendelim => '%%' ); 
  # -closedelim defaults to -opendelim, e.g. %% in this case
 
The full list of options that can be specified at object creation:

=over 4

=item *

C<-embedded =E<gt> 1>

Create the object for embedded processing, with default C<E<lt>:> and 
C<:E<gt>> delimiters. If option value is C<0>, or if the option is not 
supplied, create the object for macro processing. 

=item *

C<-opendelim =E<gt> '[[', -closedelim =E<gt> ']]'>

Create the object for embedded processing, with the supplied C<[[> and 
C<]]> delimiters. 

=item *

C<-opendelim =E<gt> '%%'>

Create the object for embedded processing, with the same C<!!> as open 
and close delimiters. 

=item *

C<-comment =E<gt> 1>

Create the C<%%[]> comment macro.

=item *

C<-file =E<gt> [ @files ]>

See also L</%LOAD> and C<macropp -f>.

=item *

C<-macro =E<gt> [ @macros ]>

Define macros, where each macro is a pair of C<name =E<gt> body>, e.g.

    my $Macro = Text::MacroScript->new(-macro => [ ["name1"=>"body1"], ["name2"=>"body2"] ] );

See also L</%DEFINE>.

=item *

C<-script =E<gt> [ @scripts ]>

Define scripts, where each script is a pair of C<name =E<gt> body>, e.g.

    my $Macro = Text::MacroScript->new(-script => [ ["name1"=>"body1"], ["name2"=>"body2"] ] );

See also L</%DEFINE_SCRIPT>.

=item *

C<-variable =E<gt> [ @svariables ]>

Define variables, where each variable is a pair of C<name =E<gt> value>, e.g.

    my $Macro = Text::MacroScript->new(-variable => [ ["name1"=>"value1"], ["name2"=>"value2"] ] );

See also L</%DEFINE_VARIABLE>.

=back

=head3 define_macro

  $Macro->define_macro( $name, $body );

Defines a macro with the given name that expands to the given body when 
called. If a macro with the same name already exists, it is silently 
overwritten. 

This is the same as the deprecated syntax:

  $Macro->define( -macro, $name, $body );

See also L</%DEFINE>.

=head3 list_macro

  $Macro->list_macro;            # lists to STDOUT
  @output = $Macro->list_macro;  # lists to array
  $Macro->list_macro(-namesonly); # only names

Lists all defined macros to C<STDOUT> or returns the result if called in 
list context. Accepts an optional parameter C<-namesonly> to list only
the macro names and not the body.

=head3 undefine_macro

  $Macro->undefine_macro( $name );

If a macro exists with the given name, it is deleted. If not, the function
does nothing.

This is the same as the deprecated syntax:

  $Macro->undefine( -macro, $name );

See also L</%UNDEFINE>.

=head3 undefine_all_macro

  $Macro->undefine_all_macro;

Delete all the defined macros.

This is the same as the deprecated syntax:

  $Macro->undefine_all( -macro );

See also L</%UNDEFINE_ALL>.

=cut
#  $Macro->define_macro( $name, \@arg_names, $body );
#The optional array of C<@arg_names> contains the names of local variables
#that are defined with the actual arguments passed to the macro when called.
#The arguments are refered in the body as other variables, prefixed with 
#C<#>, e.g.
#
#  $Macro->define_macro( 'ADD', ['A', 'B'], "#A+#B" );
#  $Macro->expand("ADD[2|3]"); --> "2+3"

=head3 define_script

  $Macro->define_script( $name, $body );

Defines a perl script with the given name that executes the given body 
when called. If a script with the same name already exists, it is 
silently overwritten. 

This is the same as the deprecated syntax:

  $Macro->define( -script, $name, $body );

See also L</%DEFINE_SCRIPT>.

=head3 list_script

  $Macro->list_script;             # lists to STDOUT
  @output = $Macro->list_script;   # lists to array
  $Macro->list_script(-namesonly); # only names

Lists all defined scripts to C<STDOUT> or returns the result if called in 
list context. Accepts an optional parameter C<-namesonly> to list only
the script names and not the body.

=head3 undefine_script

  $Macro->undefine_script( $name );

If a script exists with the given name, it is deleted. If not, the function
does nothing.

This is the same as the deprecated syntax:

  $Macro->undefine( -script, $name );

See also L</%UNDEFINE_SCRIPT>.

=head3 undefine_all_script

  $Macro->undefine_all_script;

Delete all the defined scripts.

This is the same as the deprecated syntax:

  $Macro->undefine_all( -script );

See also L</%UNDEFINE_ALL_SCRIPT>.

=cut
#  $Macro->define_script( $name, \@arg_names, $body );
#
#The optional array of C<@arg_names> contains the names of local variables
#that are defined with the actual arguments passed to the script when called.
#The arguments are referred in the body as other variables, prefixed with 
#C<#>, e.g.
#
#  $Macro->define_script( 'ADD', ['A', 'B'], "#A+#B" );
#  $Macro->expand("ADD[2|3]"); --> "5"

=head3 define_variable

  $Macro->define_variable( $name, $value );

Defines or updates a variable that can be used within macros or perl scripts
as C<#varname>. 

This is the same as the deprecated syntax:

  $Macro->define( -variable, $name, $value );

See also L</%DEFINE_VARIABLE>.

=head3 list_variable

  $Macro->list_variable;             # lists to STDOUT
  @output = $Macro->list_variable;   # lists to array
  $Macro->list_variable(-namesonly); # only names

Lists all defined variables to C<STDOUT> or returns the result if called in 
list context. Accepts an optional parameter C<-namesonly> to list only
the variable names and not the body.

=head3 undefine_variable

  $Macro->undefine_variable( $name );

If a variable exists with the given name, it is deleted. If not, the function
does nothing.

This is the same as the deprecated syntax:

  $Macro->undefine( -variable, $name );

See also L</%UNDEFINE_VARIABLE>.

=head3 undefine_all_variable

  $Macro->undefine_all_variable;

Delete all the defined variables.

This is the same as the deprecated syntax:

  $Macro->undefine_all( -variable );

See also L</%UNDEFINE_ALL_VARIABLE>.

=head3 expand

  $text = $Macro->expand( $in );
  $text = $Macro->expand( $in, $filename, $line_nr );

Expands the given C<$in> input and returns the expanded text. The C<$in> 
is either a text line or an interator that returns a sequence of text 
lines. 

The C<$filename> is optional and defaults to C<"-">. The <$line_nr> is
optional and defaults to C<1>. They are used in error messages to locate 
the error. 

The expansion processes any macro definitions and expands any macro 
calls found in the input text. C<expand()> buffers internally all the 
lines required for a multi-line definition, i.e. it can be called once 
for each line of a multi-line L</%DEFINE>. 

=head3 load_file

  $Macro->load_file( $filename );

See also L</%LOAD> and C<macropp -f>.

=head3 expand_file

  $Macro->expand_file( $filename );
  @expanded = $Macro->expand_file( $filename );

When called in C<void> context, sends output to the current output 
filehandle. When called in C<ARRAY> context, returns the list of 
expaned lines. 

Calls C<expand()> on each line of the file. 

See also L</%INCLUDE>. 

=head1 MACRO LANGUAGE

This chapter describes the macro language statements processed in the 
input files. 

=head2 Defining and using macros

These commands can appear in separate I<macro> files, and/or in the body of
files. Wherever a macroname or scriptname is encountered it will be replaced
by the body of the macro or the result of the evaluation of the script using
any parameters that are given. 

Note that if we are using an embedded approach commands, macro names and 
script names should appear between delimiters. (Except when we L</%LOAD> since
this assumes the whole file is I<embedded>.

=head3 %DEFINE

  %DEFINE macroname [macro body]
  %DEFINE macroname
  multi-line
  macro body
  #0, #1 are the first and second parameters if any used
  %END_DEFINE

Thus, in the body of a file we may have, for example:

  %DEFINE &B [Billericky Rickety Builders]
  Some arbitrary text.
  We are writing to complain to the &B about the shoddy work they did.

If we are taking the embedded approach the example above might become:

  <:%DEFINE BB [Billericky Rickety Builders]:>
  Some arbitrary text.
  We are writing to complain to the <:BB:> about the shoddy work they did.

When using an embedded approach we don't have to make the macro or script name
unique within the text, (although each must be distinct from each other),
since the delimiters are used to signify them. However since expansion applies
recursively it is still wise to make names distinctive. 

In files we would write: 

  %DEFINE MAC [The Mackintosh Macro]

The equivalent method call is:

    $Macro->define_macro( 'MAC', 'The Mackintosh Macro' );

We can call our macro anything, excluding white-space and special 
characters used while parsing the input text (C<[,],(,),#>). 

All names are case-sensitive. 

So a name like C<%*&!> is fine - indeed names which
could not normally appear in the text are recommended to avoid having the
wrong thing substituted. We should also avoid calling macros, scripts or
variables names beginning with C<#>.

Note that if we define a macro and then a script with the same name the 
script will effectively replace the macro. 

We can have parameters (for macros and scripts), e.g.:

  %DEFINE *P [The forename is #0 and the surname is #1]

Parameters used in the source text can contain square brackets since macro
will grab up to the last square bracket on the line. The only thing we can't
pass are C<|>s since these are used to separate parameters. White-space between
the macro name and the C<[> is optional in definitions but I<not allowed> in the
source text. 

Parameters are named C<#0>, C<#1>, etc. There is a limit of 100 parameters, i.e.
C<#0..#99>, and we must use all those we specify. In the example above we I<must>
use C<*P[param1|param2]>, e.g. C<*P[Jim|Hendrix]>; if we don't
C<Text::MacroScript> will croak. Note that macro names and their parameters
must all be on the same line (although this is relaxed if you use paragraph
mode).

Because we use C<#> to signify parameters if you require text that consists of a
C<#> followed by digits then you should escape the C<#>, e.g.

  %DEFINE *GRAY[<font color="\#121212">#0</font>]

We can use as many I<more> parameters than we need, for example add a third to
document: C<*P[Jim|Hendrix|Musician]> will become 
I<'The forename is Jim and the surname is Hendrix'>,
just as in the previous example; the third parameter,
I<'Musician'>, will simply be thrown away. 

If we take an embedded approach we might write this example thus: 

  <:%DEFINE P [The forename is #0 and the surname is #1]:>

and in the text, <:P[Jim|Hendrix]:> will be transformed appropriately.

If we define a macro, script or variable and later define the same name the
later definition will replace the earlier one. This is useful for making local
macro definitions over-ride global ones, simply by loading the global ones
first. 

Although macros can have plain textual names like this:

  %DEFINE MAX_INT [32767]

It is generally wise to use a prefix and/or suffix to make sure we don't 
expand something unintentionally, e.g. 

  %DEFINE $MAX_INT [65535]

B<Macro expansion is no respector of quoted strings or anything else> - 
B<if the name matches the expansion will take place!>

Multi-line definitions are permitted (here's an example I use with the lout
typesetting language): 

  %DEFINE SCENE
  @Section
    @Title {#0}
  @Begin
  @PP
  @Include {#1}
  @End @Section
  %END_DEFINE

This allows us to write the following in our lout files:

  SCENE[ The title of the scene | scene1.lt ]

which is a lot shorter than the definition.

The body of a macro may not contain a literal null. If you really need one
then use a script and represent the null as C<chr(0)>.

B<Converting a macro to a script>

This can be achieved very simply. For a one line macro simply enclose the
body between qq{ and }, e.g.

  %DEFINE $SURNAME [Baggins]

becomes

  %DEFINE_SCRIPT $SURNAME [qq{Baggins}]

For a multi-line macro use a here document, e.g.

  %DEFINE SCENE
  @Section
    @Title {#0}
  @Begin
  @PP
  @Include {#1}
  @End @Section
  %END_DEFINE

becomes

  %DEFINE_SCRIPT SCENE
  <<__EOT__
  \@Section
    \@Title {#0}
  \@Begin
  \@PP
  \@Include {#1}
  \@End \@Section
  __EOT__
  %END_DEFINE

Note that the C<@s> had to be escaped because they have a special meaning in
perl.

=head3 %UNDEFINE

Macros can be undefined in files:

  %UNDEFINE *P

and in code:

  $Macro->undefine_macro('*P'); 

Undefining a non-existing macro is not considered an error.

=head3 %UNDEFINE_ALL

All macros can be undefined in files:

  %UNDEFINE_ALL

and in code:

  $Macro->undefine_all_macro; 

=head3 %DEFINE_SCRIPT

Instead of straight textual substitution, we can have some perl executed 
(after any parameters have been replaced in the perl text): 

  %DEFINE_SCRIPT *ADD ["#0 + #1 = " . (#0 + #1)]

or by using the equivalent method call:

  $Macro->define_script( '*ADD', '"#0 + #1 = " . (#0 + #1)' );

We can call our script anything, excluding white-space characters special 
characters used while parsing the input text (C<[,],(,),#>). 

All names are case-sensitive. 

  These would be used as C<*ADD[5|11]> in the text

which would be output as: 

  These would be used as 5 + 11 = 16 in the text

In script definitions we can use an alternative way of passing parameters
instead of or in addition to the C<#0> syntax.

This is particularly useful if we want to take a variable number of parameters
since the C<#0> etc syntax does not provide for this. An array called C<@Param>
is available to our perl code that has any parameters. This allows things
like the following to be achieved: 

  %DEFINE_SCRIPT ^PEOPLE
  # We don't use the name hash number params but read straight from the
  # array:
  my $a = "friends and relatives are ";
  $a .= join ", ", @Param;
  $a;
  %END_DEFINE

The above would expand in the following text:

  Her ^PEOPLE[Anna|John|Zebadiah].

to

  Her friends and relatives are Anna, John, Zebadiah.

In addition to having access to the parameters either using the C<#0> syntax or
the C<@Param> array, we can also access any variables that have been defined
using L</%DEFINE_VARIABLE>. These are accessible either using
C<#variablename> similarly to the <#0> parameter syntax, or via the C<%Var> hash.
Although we can change both C<@Param> and C<%Var> elements in our script,
the changes to C<@Param> only apply within the script whereas changes to
C<%Var> apply from that point on globally. 

Note that if you require a literal C<#> followed by digits in a script body then
you must escape the C<#> like this C<\#>.

Here's a simple date-stamp style: 

  %DEFINE_SCRIPT *DATESTAMP
  use POSIX;
  "#0 on ".strftime("%Y/%m/%d", localtime(time));
  %END_DEFINE

If we wanted to add the above in code we'd have to make sure the 
C<$variables> weren't interpolated:

  $Macro->define_script( '*DATESTAMP', <<'__EOT__' );
  use POSIX;
  "#0 on ".strftime("%Y/%m/%d", localtime(time));
  __EOT__

Here's (a somewhat contrived example of) how the above would be used:

  <HTML>
  <HEAD><TITLE>Test Page</TITLE></HEAD>
  <BODY>
  *DATESTAMP[Last Updated]<P>
  This page is up-to-date and will remain valid until *DATESTAMP[midnight]
  </BODY>
  </HTML>

Thus we could have a file, C<test.html.m> containing:

  %DEFINE_SCRIPT *DATESTAMP
  use POSIX;
  "#0 on ".strftime("%Y/%m/%d", localtime(time));
  %END_DEFINE
  <HTML>
  <HEAD><TITLE>Test Page</TITLE></HEAD>
  <BODY>
  *DATESTAMP[Last Updated]<P>
  This page is up-to-date and will remain valid until *DATESTAMP[midnight]
  </BODY>
  </HTML>

which when expanded, either in code using C<$Macro-E<gt>expand()>, or using the
simple C<macropp> utility supplied with C<Text::MacroScript>:

  % macropp test.html.m > test.html

C<test.html> will contain just this:

  <HTML>
  <HEAD><TITLE>Test Page</TITLE></HEAD>
  <BODY>
  Last Updated on 1999/08/21<P>
  This page is up-to-date and will remain valid until midnight on 1999/08/21
  </BODY>
  </HTML>

Of course in practice we wouldn't want to define everything in-line like this.
See L</%LOAD> later for an alternative.

This example written in embedded style might be written thus:

  <:
  %DEFINE_SCRIPT DATESTAMP
  use POSIX;
  "#0 on ".strftime("%Y/%m/%d", localtime(time));
  %END_DEFINE
  :>
  <HTML>
  <HEAD><TITLE>Test Page</TITLE></HEAD>
  <BODY>
  <!-- Note how the parameter must be within the delimiters. -->
  <:DATESTAMP[Last Updated]:><P>
  This page is up-to-date and will remain valid until <:DATESTAMP[midnight]:>
  </BODY>
  </HTML>

For more (and better) HTML examples see the example file C<html.macro>.

The body of a script may not contain a literal null. If you really need one
then represent the null as C<chr(0)>. 

=head3 %UNDEFINE_SCRIPT

Scripts can be undefined in files:

  %UNDEFINE_SCRIPT *DATESTAMP

and in code:

  $Macro->undefine_script('*DATESTAMP'); 

Undefining a non-existing script is not considered an error.

=head3 %UNDEFINE_ALL_SCRIPT

All scripts can be undefined in files:

  %UNDEFINE_ALL_SCRIPT

and in code:

  $Macro->undefine_all_script; 

=head3 %DEFINE_VARIABLE

We can also define variables:

  %DEFINE_VARIABLE &*! [89.1232]

or in code:

  $Macro->define_variable( '&*!', 89.1232 );

Note that there is no multi-line version of L</%DEFINE_VARIABLE>.

All current variables are available inside L</%DEFINE> macros and 
L</%DEFINE_SCRIPT> as C<#varname>. Inside L</%DEFINE_SCRIPT> scripts they 
are also available in the C<%Var> hash: 

  %DEFINE_SCRIPT *TEST1
  $a = '';
  while( my( $key, $val ) each( %Var ) ) {
    $a .= "$key = $val\n";
  }
  $a;
  %END_DEFINE

Here's another example:
    
  %DEFINE_VARIABLE XCOORD[256]
  %DEFINE_VARIABLE YCOORD[112]
  The X coord is *SCALE[X|16] and the Y coord is *SCALE[Y|16] 
    
  %DEFINE_SCRIPT *SCALE
  my $coord = shift @Param;
  my $scale = shift @Param;
  my $val   = $Var{$coord};
  $val %= scale; # Scale it
  $val; 
  %END_DEFINE
        
Variables can be modified within script L</%DEFINE>s, e.g.

    %DEFINE_VARIABLE VV[Foxtrot]
    # VV eq 'Foxtrot'
    # other text
    # Here we use the #variable synax:
    %DEFINE_SCRIPT VV[#VV='Alpha']
    # VV eq 'Alpha' - note that we *must* refer to the script (as we've done
    # on the line following) for it to execute.
    # other text
    # Here we use perl syntax:
    %DEFINE_SCRIPT VV[$Var{'VV'}='Tango']
    # VV eq 'Tango' - note that we *must* refer to the script (as we've done
    # on the line following) for it to execute.

As we can see variables support the C<#variable> syntax similarly to parameters
which support C<#0> etc and ara available in scripts via the C<@Param> array.
Note that changing parameters within a script only apply within the script;
whereas changing variables in the C<%Var> hash in a script changes them from
that point on globally.

Variables are also used with L</%CASE>.

=head3 %UNDEFINE_VARIABLE

Variables can be undefined in files:

  %UNDEFINE_VARIABLE &*!

and in code:

  $Macro->undefine_variable('&*!'); 

Undefining a non-existing variable is not considered an error.

=head3 %UNDEFINE_ALL_VARIABLE

All variables can be undefined in files:

  %UNDEFINE_ALL_VARIABLE

and in code:

  $Macro->undefine_all_variable; 

One use of undefining everything is to ensure we get a clean start. We might
head up our files thus:

  %UNDEFINE_ALL
  %UNDEFINE_ALL_SCRIPT
  %UNDEFINE_ALL_VARIABLE
  %LOAD[mymacros]
  text goes here

=head2 Loading and including files

Although we can define macros directly in the files that require them it is often
more useful to define them separately and include them in all those that need
them. 

One way of achieving this is to load in the macros/scripts first and then
process the file(s). In code this would be achieved like this:

  $Macro->load_file( $macro_file );             # loads definitions only
  $Macro->expand_file( $file );                 # expands definitions to STDOUT
  my @expanded = $Macro->expand_file( $file );  # expands to array.

From the command line it would be achieved thus:

  % macropp -f html.macros test.html.m > test.html

One disadvantage of this approach, especially if we have lots of macro files,
is that we can easily forget which macro files are required by which text
files. One solution to this is to go back to C<%DEFINE>ing in the text files
themselves, but this would lose reusability. The answer to both these problems
is to use the C<%LOAD> command which loads the definitions from the named file at
the point it appears in the text file:

  %LOAD[~/.macro/html.macros]
  <HTML>
  <HEAD><TITLE>Test Page Again</TITLE></HEAD>
  <BODY>
  *DATESTAMP[Last Updated]<P>
  This page will remain valid until *DATESTAMP[midnight]
  </BODY>
  </HTML>

The above text has the same output but we don't have to remember or explicitly
load the macros. In code we can simply do this:

  my @expanded = $Macro->expand_file( $file );

or from the command line:

  % macropp test.html.m > test.html

At the beginning of our lout typesetting files we might put this line:

    %LOAD[local.macros]

The first line of the C<local.macros> file is:

    %LOAD[~/.macro/lout.macros]

So this loads both global macros then local ones (which if they have the same
name will of course over-ride).

This saves repeating the C<%DEFINE> definitions in all the files and makes
maintenance easier.

C<%LOAD> loads perl scripts and macros, but ignores any other text. Thus we can
use C<%LOAD>, or its method equivalent C<load_file()>, on I<any> file, and it
will only ever instantiate macros and scripts and produce no output. When we
are using embedded processing any file C<%LOAD>ed is treated as if wrapped in
delimiters.

If we want to include the entire contents of another file, and perform macro
expansion on that file then use C<%INCLUDE>, e.g.

    %INCLUDE[/path/to/file/with/scripts-and-macros-and-text]

The C<%INCLUDE> command will instantiate any macros and scripts it encounters
and include all other lines of text (with macro/script expansion) in the
output stream.

Macros and scripts are expanded in the following order:
1. scripts (longest named first, shortest named last)
2. macros  (longest named first, shortest named last)

=head3 %LOAD

  %LOAD[file]

or its code equivalent

  $Macro->load_file( $filename );

instatiates any definitions that appear in the file, but ignores any other text
and produces no output. When we are using embedded processing any file 
L</%LOAD>ed is treated as if wrapped in delimiters. 

This is equivalent to calling C<macropp -f>.

New defintions of the same macro override old defintions, thus one can first 
L</%LOAD> a global macro file, and then a local project file that can override
some of the global macros.

=head3 %INCLUDE

  %INCLUDE[file]

or its code equivalent

  $Macro->expand_file( $filename );

instatiates any definitions that appear in the file, expands definitions 
and sends any other text to the current output filehandle. 

=head3 %REQUIRE

We often want our scripts to have access to a bundle of functions that we have
created or that are in other modules. This can now be achieved by:

  %REQUIRE[/path/to/mylibrary.pl]

An example library C<macroutil.pl> is provided with examples of usage in
C<html.macro>.

There is no equivalent object method because if we're writing code we can
C<use> or c<require> as needed and if we're writing macros then we use
L</%REQUIRE>.

=head2 Control Structures

=head3 %CASE

It is possible to selectively skip parts of the text.

    %CASE[0]
    All the text here will be discarded.
    No matter how much there is.
    This is effectively a `comment' case.
    %END_CASE

The above is useful for multi-line comments.

We can also skip selectively. Here's an if...then:

    %CASE[#OS eq 'Linux']
    Skipped if the condition is FALSE. 
    %END_CASE

The condition can be any perl fragment. We can use previously defined
variables either using the C<#variable> syntax as shown above or using the
exported perl name, thus in this case either C<#OS>, or C<%Var{'OS'}>
whichever we prefer.

If the condition is true the text is output with macro/script expansion as
normal; if the condition is false the text is skipped.

The if...then...else structure:

    %DEFINE_VARIABLE OS[Linux]

    %CASE[$Var{'OS'} eq 'Linux']
    Linux specific stuff.
    %CASE[#OS ne 'Linux']
    Non-linux stuff - note that both references to the OS variable are
    identical in the expression (#OS is converted internally to $Var{'0S'} so
    the eval sees the same code in both cases
    %END_CASE

Although nested L</%CASE>s are not supported we can get the same functionality
(and indeed more versatility because we can use full perl expressions), e.g.:

    %DEFINE_VARIABLE TARGET[Linux]

    %CASE[#TARGET eq 'Win32' or #TARGET eq 'DOS']
    Win32/DOS stuff.
    %CASE[#TARGET eq 'Win32']
    Win32 only stuff.
    %CASE[#TARGET eq 'DOS']
    DOS only stuff.
    %CASE[#TARGET eq 'Win32' or #TARGET eq 'DOS']
    More Win32/DOS stuff.
    %END_CASE

Although C<macropp> doesn't support nested L</%CASE>'s we can still represent
logic like this:

    if cond1 then
        if cond2
            do cond1 + cond2 stuff
        else
            do cond1 stuff
        end if
    else
        do other stuff
    end if

By `unrolling' the expression and writing something like this:

    %CASE[#cond1 and #cond2]
        do cond1 + cond2 stuff
    %CASE[#cond1 and (not #cond2)]
        do cond1 stuff
    %CASE[(not #cond1) and (not #cond2)]
        do other stuff
    %END_CASE

In other words we must fully specify the conditions for each case.

We can use any other macro/script command within L</%CASE> commands, e.g.
L</%DEFINE>s, etc., as well as have any text that will be macro/script expanded
as normal.

=head2 Comments

Generally the text files that we process are in formats that support
commenting, e.g. HTML:

    <!-- This is an HTML comment -->

Sometimes however we want to put comments in our macro source files that won't
end up in the output files. One simple way of achieving this is to define a
macro whose body is empty; when its called with any number of parameters (our
comments), their text is thrown away:

  %DEFINE %%[]

which is used like this in texts:

  The comment comes %%[Here | [anything] put here will disappear]here!

The output of the above will be:

    The comment comes here!

We can add the definition in code:

    $Macro->define( -macro, '%%', '' );

Or the macro can be added automatically for us when we create the Macro
object:

    my $Macro = Text::MacroScript->new( -comment => 1 ); 
    # All other options may be used too of course.

However the easiest way to comment is to use L</%CASE>:

    %CASE[0]
    This unconditionally skips text up until the end marker since the
    condition is always false.
    %END_CASE

=head1 IMPORTABLE FUNCTIONS

In version 1.25 I introduced some useful importable functions. These have now
been removed from the module. Instead I supply a perl library C<macroutil.pl>
which has these functions (abspath, relpath, today) since Text::MacroScript
can now `require' in any library file you like using the L</%REQUIRE>
directive.

=head1 EXAMPLES

I now include a sample C<html.macro> file for use with HTML documents. It uses
the C<macrodir> program (supplied). The macro examples include macros which
use C<relpath> and also two macros which will include `new' and `updated'
images up until a specified expiry date using variables.

(Also see DESCRIPTION.)

=head1 BUGS

Lousy error reporting for embedded perl in most cases.

=head1 AUTHOR

Mark Summerfield. I can be contacted as <summer@perlpress.com> -
please include the word 'macro' in the subject line.

=head1 MAINTAINER

Since 2015, Paulo Custodio. 

This module repository is kept in Github, please feel free to submit issues,
fork and send pull requests.

    https://github.com/pauloscustodio/Text-MacroScript

=head1 COPYRIGHT

Copyright (c) Mark Summerfield 1999-2000. All Rights Reserved.

Copyright (c) Paulo Custodio 2015. All Rights Reserved.

This module may be used/distributed/modified under the LGPL. 

=cut
