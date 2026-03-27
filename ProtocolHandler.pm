package Plugins::InsightTimer::ProtocolHandler;

use strict;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::InsightTimer::API;

use base qw(Slim::Player::Protocols::HTTPS);

my $log   = logger('plugin.insighttimer');
my $cache = Slim::Utils::Cache->new;
my $prefs = preferences('plugin.insighttimer');

sub canSkip { 1 }

sub getFormatForURL {
	my ($class, $url) = @_;
	# Default to mp3; overridden per-song by formatOverride if HLS
	return 'mp3';
}

sub formatOverride {
	my ($class, $song) = @_;
	return $song->pluginData('format') || 'mp3';
}

# Avoid scanning remote URLs
sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->($args->{song}->currentTrack());
}

# Source for AudioScrobbler
sub audioScrobblerSource { 'P' }

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->track->url;
	my $itemId = _getId($url);

	if (!$itemId) {
		$log->error("Can't extract item ID from URL: $url");
		return $errorCb->("Invalid Insight Timer URL");
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Resolving stream for item: $itemId");

	Plugins::InsightTimer::API::getItem(sub {
		my $item = shift;

		if (!$item) {
			$log->error("Failed to fetch item detail for: $itemId");
			return $errorCb->("Failed to get track info");
		}

		my ($streamUrl, $format) = Plugins::InsightTimer::API::getStreamUrl($item);
		if (!$streamUrl) {
			$log->error("No stream URL found for: $itemId");
			return $errorCb->("No stream available");
		}

		main::DEBUGLOG && $log->is_debug && $log->debug("Stream URL ($format): $streamUrl");

		# Cache metadata for getMetadataFor
		my $meta = {
			title    => $item->{title},
			artist   => $item->{publisher}{name} || '',
			duration => $item->{media_length},
			icon     => Plugins::InsightTimer::API::getImageUrl($item),
			cover    => Plugins::InsightTimer::API::getImageUrl($item),
			type     => $format eq 'hls' ? 'aac' : 'mp3',
			bitrate  => $format eq 'hls' ? 'VBR' : '128k CBR',
		};
		$cache->set('it_meta_' . $itemId, $meta, Plugins::InsightTimer::API::DETAIL_TTL);

		$song->pluginData(format => ($format eq 'hls' ? 'aac' : 'mp3'));
		$song->streamUrl($streamUrl);

		# Record in recent history
		Plugins::InsightTimer::Plugin->addToRecent({
			id             => $itemId,
			title          => $item->{title},
			publisher_name => $item->{publisher}{name},
			duration       => $item->{media_length},
		});

		$successCb->();
	}, $itemId);
}

my @pendingMeta;

sub getMetadataFor {
	my ($class, $client, $url) = @_;

	return {} unless $url;

	my $itemId = _getId($url);
	my $meta = $cache->get('it_meta_' . ($itemId || ''));

	return $meta if ref $meta;

	my $icon = $class->getIcon();

	# Fetch metadata asynchronously if not cached
	if ($itemId && $client) {
		my $now = time();
		@pendingMeta = grep { $_->{time} + 60 > $now } @pendingMeta;

		if (!(grep { $_->{id} eq $itemId } @pendingMeta) && scalar(@pendingMeta) < 10) {
			push @pendingMeta, { id => $itemId, time => $now };

			Plugins::InsightTimer::API::getItem(sub {
				my $item = shift;
				@pendingMeta = grep { $_->{id} ne $itemId } @pendingMeta;
				return unless $item;

				my $fetched = {
					title    => $item->{title},
					artist   => $item->{publisher}{name} || '',
					duration => $item->{media_length},
					icon     => Plugins::InsightTimer::API::getImageUrl($item) || $icon,
					cover    => Plugins::InsightTimer::API::getImageUrl($item) || $icon,
					type     => $prefs->get('preferHLS') ? 'aac' : 'mp3',
					bitrate  => $prefs->get('preferHLS') ? 'VBR' : '128k CBR',
				};
				$cache->set('it_meta_' . $itemId, $fetched, Plugins::InsightTimer::API::DETAIL_TTL);

				return if @pendingMeta;

				$client->currentPlaylistUpdateTime(Time::HiRes::time());
				Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
			}, $itemId);
		}
	}

	return {
		type  => 'mp3',
		icon  => $icon,
		cover => $icon,
	};
}

sub getIcon {
	return Plugins::InsightTimer::Plugin->_pluginDataFor('icon');
}

# Extract item ID from insighttimer://{id}.mp3 URL
sub _getId {
	my ($url) = @_;

	return undef unless $url;

	if ($url =~ m{^insighttimer://([a-z0-9]+)}) {
		return $1;
	}

	return undef;
}

1;
