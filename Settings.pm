package Plugins::InsightTimer::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.insighttimer');

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_INSIGHTTIMER_NAME') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/InsightTimer/settings.html') }

sub prefs { return ($prefs, qw(language itemsPerPage)) }

1;
