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
sub isRemote { 1 }

# HLS streams are transcoded via ffmpeg (custom-convert.conf: m3u8 -> flc)
sub getFormatForURL { 'm3u8' }

sub formatOverride {
	my ($class, $song) = @_;
	return $song->pluginData('format') || 'm3u8';
}

# Avoid scanning remote URLs
sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->($args->{song}->currentTrack());
}

sub audioScrobblerSource { 'P' }

# Override new to pass the resolved stream URL to the HTTPS parent class
sub new {
	my $class = shift;
	my $args  = shift;

	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;

	$log->info("Streaming: $streamUrl");

	my $sock = $class->SUPER::new({
		url    => $streamUrl,
		song   => $args->{song},
		client => $args->{client},
	}) || return;

	return $sock;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->track->url;
	my $itemId = _getId($url);

	if (!$itemId) {
		$log->error("Can't extract item ID from URL: $url");
		return $errorCb->("Invalid Insight Timer URL");
	}

	$log->info("Resolving stream for item: $itemId");

	Plugins::InsightTimer::API::getItem(sub {
		my $item = shift;

		if (!$item) {
			$log->error("Failed to fetch item detail for: $itemId");
			return $errorCb->("Failed to get track info");
		}

		my ($streamUrl, $streamFormat) = Plugins::InsightTimer::API::getStreamUrl($item);
		if (!$streamUrl) {
			$log->error("No stream URL found for: $itemId");
			return $errorCb->("No stream available");
		}

		$log->info("Stream URL ($streamFormat): $streamUrl");

		my $publisher_name = ($item->{publisher} && $item->{publisher}{name}) || '';
		my $image = Plugins::InsightTimer::API::getImageUrl($item);

		my $meta = {
			title    => $item->{title},
			artist   => $publisher_name,
			duration => $item->{media_length},
			icon     => $image,
			cover    => $image,
			type     => 'flc',
			bitrate  => 'VBR',
		};
		$cache->set('it_meta_' . $itemId, $meta, Plugins::InsightTimer::API::DETAIL_TTL);

		# Set the HLS URL as the stream URL — ffmpeg reads it directly
		# via custom-convert.conf rule (m3u8 -> flc)
		$song->pluginData(format => 'm3u8');
		$song->streamUrl($streamUrl);

		# Record in recent history
		Plugins::InsightTimer::Plugin->addToRecent({
			id             => $itemId,
			title          => $item->{title},
			publisher_id   => ($item->{publisher} && $item->{publisher}{id}) || '',
			publisher_name => $publisher_name,
			duration       => $item->{media_length},
			content_type   => $item->{content_type} || '',
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

	if ($itemId && $client) {
		my $now = time();
		@pendingMeta = grep { $_->{time} + 60 > $now } @pendingMeta;

		if (!(grep { $_->{id} eq $itemId } @pendingMeta) && scalar(@pendingMeta) < 10) {
			push @pendingMeta, { id => $itemId, time => $now };

			Plugins::InsightTimer::API::getItem(sub {
				my $item = shift;
				@pendingMeta = grep { $_->{id} ne $itemId } @pendingMeta;

				if ($item) {
					my $image = Plugins::InsightTimer::API::getImageUrl($item) || $icon;
					my $fetched = {
						title    => $item->{title},
						artist   => ($item->{publisher} && $item->{publisher}{name}) || '',
						duration => $item->{media_length},
						icon     => $image,
						cover    => $image,
						type     => 'flc',
						bitrate  => 'VBR',
					};
					$cache->set('it_meta_' . $itemId, $fetched, Plugins::InsightTimer::API::DETAIL_TTL);
				}

				$client->currentPlaylistUpdateTime(Time::HiRes::time());
				Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
			}, $itemId);
		}
	}

	return {
		type  => 'flc',
		icon  => $icon,
		cover => $icon,
	};
}

sub getIcon {
	return Plugins::InsightTimer::Plugin->_pluginDataFor('icon');
}

sub _getId {
	my ($url) = @_;

	return undef unless $url;

	if ($url =~ m{^insighttimer://([a-zA-Z0-9_-]+)}) {
		return $1;
	}

	return undef;
}

1;
