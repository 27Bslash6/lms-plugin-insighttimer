package Plugins::InsightTimer::API;

use strict;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant FILTER_URL => 'https://filtering.insighttimer-api.net/api/v1/single-tracks/filter';
use constant DETAIL_URL => 'https://libraryitems.insighttimer.com/';

use constant SEARCH_TTL   => 300;    # 5 min — match CDN cache
use constant DETAIL_TTL   => 3600;   # 1 hour
use constant IMAGE_TTL    => 86400;  # 24 hours

use constant DEFAULT_LIMIT => 50;
use constant MAX_FAVORITES => 500;
use constant MAX_TEACHERS  => 50;
use constant MAX_RECENT    => 50;

# Curated categories: slug => string key
use constant CATEGORIES => [
	{ slug => 'sleep',       stringKey => 'PLUGIN_INSIGHTTIMER_SLEEP' },
	{ slug => 'stress',      stringKey => 'PLUGIN_INSIGHTTIMER_STRESS' },
	{ slug => 'focus',       stringKey => 'PLUGIN_INSIGHTTIMER_FOCUS' },
	{ slug => 'selflove',    stringKey => 'PLUGIN_INSIGHTTIMER_SELFLOVE' },
	{ slug => 'morning',     stringKey => 'PLUGIN_INSIGHTTIMER_MORNING' },
	{ slug => 'yoganidra',   stringKey => 'PLUGIN_INSIGHTTIMER_YOGANIDRA' },
	{ slug => 'bodyscan',    stringKey => 'PLUGIN_INSIGHTTIMER_BODYSCAN' },
	{ slug => 'breathwork',  stringKey => 'PLUGIN_INSIGHTTIMER_BREATHWORK' },
];

# Content types: filter value => string key
use constant CONTENT_TYPES => [
	{ type => 'guided', stringKey => 'PLUGIN_INSIGHTTIMER_GUIDED' },
	{ type => 'music',  stringKey => 'PLUGIN_INSIGHTTIMER_MUSIC' },
	{ type => 'talks',  stringKey => 'PLUGIN_INSIGHTTIMER_TALKS' },
];

my $cache = Slim::Utils::Cache->new;
my $log   = logger('plugin.insighttimer');
my $prefs = preferences('plugin.insighttimer');

# search(\&callback, { params => { query => 'sleep', content_types => 'guided', ... } })
# Calls the IT filter API. Callback receives ($items_arrayref) or undef on error.
sub search {
	my ($cb, $args) = @_;

	my $params = $args->{params} || {};
	my $lang = $params->{content_langs} || $prefs->get('language') || 'en';
	my $limit = $params->{limit} || $prefs->get('itemsPerPage') || DEFAULT_LIMIT;

	my @query_parts;
	push @query_parts, 'content_langs=' . uri_escape_utf8($lang);
	push @query_parts, 'limit=' . $limit;

	for my $key (qw(query content_types topics sort_option offset length_range_in_seconds voice_gender publisher_id)) {
		if (defined $params->{$key} && $params->{$key} ne '') {
			push @query_parts, $key . '=' . uri_escape_utf8($params->{$key});
		}
	}

	my $url = FILTER_URL . '?' . join('&', @query_parts);

	my $cached = $cache->get('it_search_' . $url);
	if ($cached) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Cache hit for $url");
		return $cb->($cached);
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Fetching: $url");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $content = eval { from_json($http->content) };

			if ($@ || !$content || ref $content ne 'ARRAY') {
				$log->error("Failed to parse filter response: " . ($@ || 'not an array'));
				return $cb->(undef);
			}

			my $items = _normalizeFilterResults($content);
			$cache->set('it_search_' . $url, $items, SEARCH_TTL);
			$cb->($items);
		},
		sub {
			my ($http, $error) = @_;
			$log->error("Filter API error: $error");
			$cb->(undef);
		},
		{ timeout => 30 },
	)->get($url);
}

# getItem(\&callback, $itemId)
# Fetches full item detail. Callback receives ($item_hashref) or undef on error.
sub getItem {
	my ($cb, $itemId) = @_;

	return $cb->(undef) unless $itemId;

	my $cached = $cache->get('it_detail_' . $itemId);
	if ($cached) {
		return $cb->($cached);
	}

	my $url = DETAIL_URL . $itemId . '/data/libraryitem.json';

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $item = eval { from_json($http->content) };

			if ($@ || !$item || !ref $item) {
				$log->error("Failed to parse item detail: " . ($@ || 'empty'));
				return $cb->(undef);
			}

			$cache->set('it_detail_' . $itemId, $item, DETAIL_TTL);
			$cb->($item);
		},
		sub {
			my ($http, $error) = @_;
			$log->error("Item detail API error for $itemId: $error");
			$cb->(undef);
		},
		{ timeout => 30 },
	)->get($url);
}

# getStreamUrl($item) — returns stream URL based on user's preferred format
# Synchronous — operates on already-fetched item detail data.
# Returns ($url, $format) where $format is 'mp3' or 'hls'
sub getStreamUrl {
	my ($item) = @_;

	return (undef, undef) unless $item;

	my $preferHLS = $prefs->get('preferHLS');

	if ($preferHLS) {
		# Try HLS first, fall back to MP3
		if (my $url = _getHLSUrl($item)) {
			return ($url, 'hls');
		}
		if (my $url = _getMP3Url($item)) {
			return ($url, 'mp3');
		}
	} else {
		# Try MP3 first, fall back to HLS
		if (my $url = _getMP3Url($item)) {
			return ($url, 'mp3');
		}
		if (my $url = _getHLSUrl($item)) {
			return ($url, 'hls');
		}
	}

	return (undef, undef);
}

sub _getHLSUrl {
	my ($item) = @_;
	if ($item->{media_paths} && ref $item->{media_paths} eq 'ARRAY') {
		for my $url (@{$item->{media_paths}}) {
			return $url if $url && $url =~ /^https:/;
		}
		return $item->{media_paths}[0] if $item->{media_paths}[0];
	}
	return undef;
}

sub _getMP3Url {
	my ($item) = @_;
	if ($item->{standard_media_paths} && ref $item->{standard_media_paths} eq 'ARRAY') {
		for my $url (@{$item->{standard_media_paths}}) {
			return $url if $url && $url =~ /^https:/;
		}
		return $item->{standard_media_paths}[0] if $item->{standard_media_paths}[0];
	}
	return undef;
}

# getImageUrl($item) — returns image URL from item data (filter or detail format)
sub getImageUrl {
	my ($item) = @_;

	return undef unless $item;

	# Detail format: picture_square.medium or picture.medium
	if (ref $item->{picture_square}) {
		return $item->{picture_square}{medium} || $item->{picture_square}{small};
	}
	if (ref $item->{picture}) {
		return $item->{picture}{medium} || $item->{picture}{small};
	}

	return undef;
}

# formatDuration($seconds) — returns human-readable duration string
sub formatDuration {
	my ($seconds) = @_;

	return '' unless $seconds;

	my $min = int($seconds / 60);
	if ($min >= 60) {
		my $hr = int($min / 60);
		$min = $min % 60;
		return $min > 0 ? "${hr}h ${min}m" : "${hr}h";
	}

	return "${min}m";
}

# _normalizeFilterResults(\@raw) — normalize filter API response to flat item hashes
sub _normalizeFilterResults {
	my ($raw) = @_;

	return [ map {
		my $s = $_->{item_summary}{library_item_summary};
		my $m = $_->{metadata} || {};
		{
			id             => $s->{id},
			title          => $s->{title},
			content_type   => $s->{content_type},
			duration       => $s->{media_length},
			rating         => $s->{rating_score},
			rating_count   => $s->{rating_count},
			publisher_id   => $s->{publisher}{id},
			publisher_name => $s->{publisher}{name},
			media_paths    => $s->{media_paths},
			play_count     => $m->{play_count},
		};
	} @$raw ];
}

1;
