#!/usr/bin/perl

# Copyright (c) 2015 Paulo Custodio. All Rights Reserved.
# May be used/distributed under the GPL.

use strict;
use warnings;
use Capture::Tiny 'capture';
use Test::Differences;
use Test::More;

my $ms;
my($out,$err,@res);
use_ok 'Text::MacroScript';
require_ok 't/mytests.pl';

sub void(&) { $_[0]->(); () }

# syntax errors
$ms = new_ok('Text::MacroScript');
eval {$ms->list()};
check_error(__LINE__-1, $@, " method not supported __LOC__.\n");

# list...
$ms = new_ok('Text::MacroScript' => [ 
				-variable => [ 
						[ V1 => 1 ],
						[ V2 => 2 ],
					],
				-macro => [ 
						[ M1 => 1 ],
						[ M2 => "2\n2\n" ],
					],
				-script => [ 
						[ S1 => 1 ],
						[ S2 => "2\n2\n" ],
					],
				]);

@res = $ms->list_macro(-namesonly);
is_deeply \@res, ["%DEFINE M1\n", 
				  "%DEFINE M2\n"];

@res = $ms->list(-macro, -namesonly);
is_deeply \@res, ["%DEFINE M1\n", 
				  "%DEFINE M2\n"];

@res = $ms->list_macro;
is_deeply \@res, ["%DEFINE M1 [1]\n", 
				  "%DEFINE M2\n".
				  "2\n".
				  "2\n".
				  "%END_DEFINE\n"];

@res = $ms->list(-macro);
is_deeply \@res, ["%DEFINE M1 [1]\n", 
				  "%DEFINE M2\n".
				  "2\n".
				  "2\n".
				  "%END_DEFINE\n"];

($out,$err,@res) = capture { void { $ms->list_macro(-namesonly); } };
eq_or_diff $out, "%DEFINE M1\n".
				 "%DEFINE M2\n";
is $err, "";
is_deeply \@res, [];

($out,$err,@res) = capture { void { $ms->list(-macro, -namesonly); } };
eq_or_diff $out, "%DEFINE M1\n".
				 "%DEFINE M2\n";
is $err, "";
is_deeply \@res, [];

($out,$err,@res) = capture { void { $ms->list_macro; } };
eq_or_diff $out, "%DEFINE M1 [1]\n".
				 "%DEFINE M2\n".
				 "2\n".
				 "2\n".
				 "%END_DEFINE\n";
is $err, "";
is_deeply \@res, [];

($out,$err,@res) = capture { void { $ms->list(-macro); } };
eq_or_diff $out, "%DEFINE M1 [1]\n".
				 "%DEFINE M2\n".
				 "2\n".
				 "2\n".
				 "%END_DEFINE\n";
is $err, "";
is_deeply \@res, [];

done_testing;
