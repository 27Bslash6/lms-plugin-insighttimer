package Plugins::InsightTimer::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.insighttimer');

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_INSIGHTTIMER_NAME') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/InsightTimer/settings.html') }

sub prefs { return ($prefs, qw(language itemsPerPage)) }

sub handler {
	my ($class, $client, $params) = @_;
	$params->{ffmpeg} = Slim::Utils::Misc::findbin('ffmpeg') ? 1 : 0;
	return $class->SUPER::handler($client, $params);
}

1;
