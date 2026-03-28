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
use constant TOPICS_URL => 'https://topics.insighttimer-api.net/topics.json';

use constant SEARCH_TTL   => 300;    # 5 min — match CDN cache
use constant DETAIL_TTL   => 3600;   # 1 hour
use constant TOPICS_TTL   => 86400;  # 24 hours — topics rarely change

use constant DEFAULT_LIMIT => 50;
use constant MAX_FAVORITES => 500;
use constant MAX_TEACHERS  => 50;
use constant MAX_RECENT    => 50;

# Content types: filter value => display name
use constant CONTENT_TYPES => [
	{ type => 'guided', name => 'Guided Meditations' },
	{ type => 'music',  name => 'Music' },
	{ type => 'talks',  name => 'Talks' },
];

# Topic groups we want to show as browse categories
use constant BROWSE_TOPIC_GROUPS => ['BENEFITS', 'PRACTICES'];

my $cache = Slim::Utils::Cache->new;
my $log   = logger('plugin.insighttimer');
my $prefs = preferences('plugin.insighttimer');

# search(\&callback, { params => { query => 'sleep', content_types => 'guided', ... } })
sub search {
	my ($cb, $args) = @_;

	my $params = $args->{params} || {};
	my $lang = $params->{content_langs} || $prefs->get('language') || 'en';
	my $limit = int($params->{limit} || $prefs->get('itemsPerPage') || DEFAULT_LIMIT);
	$limit = DEFAULT_LIMIT if $limit < 1 || $limit > 500;

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
		return $cb->($cached);
	}

	$log->info("Fetching: $url");

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
sub getItem {
	my ($cb, $itemId) = @_;

	return $cb->(undef) unless $itemId && $itemId =~ /^[a-zA-Z0-9_-]+$/;

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

# getTopics(\&callback) — fetches dynamic topic list from IT API
sub getTopics {
	my ($cb) = @_;

	my $cached = $cache->get('it_topics');
	if ($cached) {
		return $cb->($cached);
	}

	$log->info("Fetching topics from: " . TOPICS_URL);

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $topics = eval { from_json($http->content) };

			if ($@ || !$topics || ref $topics ne 'ARRAY') {
				$log->error("Failed to parse topics: " . ($@ || 'not an array'));
				return $cb->(undef);
			}

			# Filter to browseable groups and build simple list
			my %groups = map { $_ => 1 } @{BROWSE_TOPIC_GROUPS()};
			my @filtered;
			for my $t (@$topics) {
				next unless $t->{topic_group} && $groups{$t->{topic_group}};
				my $name = $t->{id} || next;
				# Title-case the slug: "selflove" -> "Selflove", "bodyscan" -> "Bodyscan"
				$name = ucfirst($name);
				# Try to get English translation if available
				if ($t->{translations} && $t->{translations}{en} && $t->{translations}{en}{name}) {
					$name = $t->{translations}{en}{name};
				}
				push @filtered, {
					slug  => $t->{id},
					name  => $name,
					group => $t->{topic_group},
				};
			}

			# Sort: BENEFITS first, then PRACTICES, alpha within each
			@filtered = sort {
				($a->{group} cmp $b->{group}) || ($a->{name} cmp $b->{name})
			} @filtered;

			$cache->set('it_topics', \@filtered, TOPICS_TTL);
			$cb->(\@filtered);
		},
		sub {
			my ($http, $error) = @_;
			$log->error("Topics API error: $error");
			$cb->(undef);
		},
		{ timeout => 30 },
	)->get(TOPICS_URL);
}

# getStreamUrl($item) — returns ($url, $format)
# Prefers HLS (higher quality, adaptive bitrate AAC) which squeezelite/WiiM handle natively.
# Falls back to MP3 if no HLS available.
sub getStreamUrl {
	my ($item) = @_;

	return (undef, undef) unless $item;

	# Prefer HLS — higher quality, resolves from libraryitems.insighttimer.com (DNS works)
	# MP3 hostnames (staticmp3.insighttimer.com) may not resolve in all environments
	if (my $url = _getUrlFromPaths($item, 'media_paths')) {
		return ($url, 'aac');
	}

	# Fallback to MP3
	if (my $url = _getUrlFromPaths($item, 'standard_media_paths')) {
		return ($url, 'mp3');
	}

	return (undef, undef);
}

sub _getUrlFromPaths {
	my ($item, $key) = @_;
	if ($item->{$key} && ref $item->{$key} eq 'ARRAY') {
		for my $url (@{$item->{$key}}) {
			return $url if $url && $url =~ /^https:/;
		}
	}
	return undef;
}

# getImageUrl($item) — returns image URL from item data
# The picture/picture_square fields point to publicdata.insighttimer.com which is dead (NXDOMAIN).
# Use the predictable libraryitems URL pattern instead.
sub getImageUrl {
	my ($item) = @_;

	return undef unless $item && $item->{id};
	return DETAIL_URL . $item->{id} . '/pictures/rectangle_medium.jpeg';
}

# formatDuration($seconds)
sub formatDuration {
	my ($seconds) = @_;

	return '' unless $seconds;

	my $min = int($seconds / 60);
	if ($min >= 60) {
		my $hr = int($min / 60);
		$min = $min % 60;
		return $min > 0 ? "${hr}h ${min}m" : "${hr}h";
	}

	return "${min}m" if $min > 0;
	return "<1m";
}

# _normalizeFilterResults(\@raw)
sub _normalizeFilterResults {
	my ($raw) = @_;

	return [ grep { defined $_->{id} } map {
		my $s = ($_->{item_summary} && $_->{item_summary}{library_item_summary}) || {};
		my $m = $_->{metadata} || {};
		my $pub = $s->{publisher} || {};
		{
			id             => $s->{id},
			title          => $s->{title},
			content_type   => $s->{content_type},
			duration       => $s->{media_length},
			rating         => $s->{rating_score},
			rating_count   => $s->{rating_count},
			publisher_id   => $pub->{id},
			publisher_name => $pub->{name},
			play_count     => $m->{play_count},
		};
	} @$raw ];
}

1;
