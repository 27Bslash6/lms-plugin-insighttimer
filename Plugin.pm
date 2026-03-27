package Plugins::InsightTimer::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::InsightTimer::API;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.insighttimer',
	description  => 'PLUGIN_INSIGHTTIMER_NAME',
	defaultLevel => 'WARN',
});

my $prefs = preferences('plugin.insighttimer');

sub initPlugin {
	my $class = shift;

	$prefs->init({
		language     => 'en',
		itemsPerPage => 50,
		preferHLS    => 1,
		favorites    => [],
		teachers     => [],
		recent       => [],
	});

	if (main::WEBUI) {
		require Plugins::InsightTimer::Settings;
		Plugins::InsightTimer::Settings->new();
	}

	Slim::Player::ProtocolHandlers->registerHandler(
		'insighttimer', 'Plugins::InsightTimer::ProtocolHandler'
	);

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'insighttimer',
		menu   => 'apps',
		is_app => 1,
	);
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	my $items = [
		{
			name  => cstring($client, 'PLUGIN_INSIGHTTIMER_SEARCH'),
			image => 'html/images/search.png',
			type  => 'search',
			url   => \&searchHandler,
		},
		{
			name  => cstring($client, 'PLUGIN_INSIGHTTIMER_BROWSE_CATEGORY'),
			type  => 'link',
			url   => \&browseCategories,
		},
		{
			name  => cstring($client, 'PLUGIN_INSIGHTTIMER_BROWSE_TYPE'),
			type  => 'link',
			url   => \&browseTypes,
		},
		{
			name  => cstring($client, 'PLUGIN_INSIGHTTIMER_POPULAR'),
			type  => 'link',
			url   => \&browseList,
			passthrough => [{ sort_option => 'most_played_last_7_days' }],
		},
		{
			name  => cstring($client, 'PLUGIN_INSIGHTTIMER_HIGHEST_RATED'),
			type  => 'link',
			url   => \&browseList,
			passthrough => [{ sort_option => 'highest_rated' }],
		},
		{
			name  => cstring($client, 'PLUGIN_INSIGHTTIMER_FAVORITES'),
			type  => 'link',
			url   => \&showFavorites,
		},
		{
			name  => cstring($client, 'PLUGIN_INSIGHTTIMER_TEACHERS'),
			type  => 'link',
			url   => \&showTeachers,
		},
		{
			name  => cstring($client, 'PLUGIN_INSIGHTTIMER_RECENT'),
			type  => 'link',
			url   => \&showRecent,
		},
	];

	$cb->({ items => $items });
}

# --- Search ---

sub searchHandler {
	my ($client, $cb, $params) = @_;

	my $query = $params->{search};
	return $cb->({ items => [] }) unless $query;

	Plugins::InsightTimer::API::search(sub {
		my $items = shift;
		$cb->({ items => _renderItems($client, $items) });
	}, { params => { query => $query } });
}

# --- Browse by Category ---

sub browseCategories {
	my ($client, $cb) = @_;

	my $items = [ map {
		{
			name => cstring($client, $_->{stringKey}),
			type => 'link',
			url  => \&browseList,
			passthrough => [{ topics => $_->{slug}, sort_option => 'popular' }],
		}
	} @{Plugins::InsightTimer::API::CATEGORIES} ];

	$cb->({ items => $items });
}

# --- Browse by Type ---

sub browseTypes {
	my ($client, $cb) = @_;

	my $items = [ map {
		{
			name => cstring($client, $_->{stringKey}),
			type => 'link',
			url  => \&browseList,
			passthrough => [{ content_types => $_->{type}, sort_option => 'popular' }],
		}
	} @{Plugins::InsightTimer::API::CONTENT_TYPES} ];

	$cb->({ items => $items });
}

# --- Generic browse list with pagination ---

sub browseList {
	my ($client, $cb, $params, $args) = @_;

	my $offset = $params->{offset} || $args->{offset} || 0;
	my $limit = $prefs->get('itemsPerPage') || Plugins::InsightTimer::API::DEFAULT_LIMIT;

	my $apiParams = {
		offset => $offset,
		limit  => $limit,
	};

	# Pass through filter params from passthrough
	for my $key (qw(sort_option topics content_types query publisher_id)) {
		$apiParams->{$key} = $args->{$key} if defined $args->{$key};
	}

	Plugins::InsightTimer::API::search(sub {
		my $items = shift;

		my $rendered = _renderItems($client, $items);

		# Add "More..." pagination link if we got a full page
		if ($items && scalar @$items >= $limit) {
			my $nextArgs = { %$args, offset => $offset + $limit };
			push @$rendered, {
				name => cstring($client, 'NEXT'),
				type => 'link',
				url  => \&browseList,
				passthrough => [$nextArgs],
			};
		}

		$cb->({ items => $rendered });
	}, { params => $apiParams });
}

# --- Render items as OPML ---

sub _renderItems {
	my ($client, $items) = @_;

	return [] unless $items && ref $items eq 'ARRAY';

	return [ map {
		my $item = $_;
		my $duration = Plugins::InsightTimer::API::formatDuration($item->{duration});
		my $subtitle = $item->{publisher_name} || '';
		$subtitle .= " ($duration)" if $duration;

		{
			name    => $item->{title},
			line1   => $item->{title},
			line2   => $subtitle,
			type    => 'playlist',
			url     => \&itemMenu,
			passthrough => [{
				id             => $item->{id},
				title          => $item->{title},
				publisher_id   => $item->{publisher_id},
				publisher_name => $item->{publisher_name},
				duration       => $item->{duration},
				content_type   => $item->{content_type},
			}],
		};
	} @$items ];
}

# --- Item action menu ---

sub itemMenu {
	my ($client, $cb, $params, $args) = @_;

	my $url = 'insighttimer://' . $args->{id} . '.mp3';

	my $items = [
		{
			name    => cstring($client, 'PLUGIN_INSIGHTTIMER_PLAY'),
			type    => 'audio',
			url     => $url,
			on_select => 'play',
		},
		{
			name => _isFavorite($args->{id})
				? cstring($client, 'PLUGIN_INSIGHTTIMER_REMOVE_FAVORITE')
				: cstring($client, 'PLUGIN_INSIGHTTIMER_ADD_FAVORITE'),
			type => 'link',
			url  => \&toggleFavorite,
			passthrough => [$args],
			nextWindow => 'parent',
		},
		{
			name => _isFollowing($args->{publisher_id})
				? cstring($client, 'PLUGIN_INSIGHTTIMER_UNFOLLOW_TEACHER')
				: cstring($client, 'PLUGIN_INSIGHTTIMER_FOLLOW_TEACHER'),
			type => 'link',
			url  => \&toggleTeacher,
			passthrough => [$args],
			nextWindow => 'parent',
		},
		{
			name => cstring($client, 'PLUGIN_INSIGHTTIMER_MORE_FROM_TEACHER'),
			type => 'link',
			url  => \&browseList,
			passthrough => [{ publisher_id => $args->{publisher_id}, sort_option => 'popular' }],
		},
	];

	$cb->({ items => $items });
}

# --- Favorites ---

sub showFavorites {
	my ($client, $cb) = @_;

	my $favorites = $prefs->get('favorites') || [];

	if (!scalar @$favorites) {
		return $cb->({ items => [{
			name => cstring($client, 'PLUGIN_INSIGHTTIMER_NO_FAVORITES'),
			type => 'textarea',
		}] });
	}

	my $items = [ map {
		my $fav = $_;
		my $duration = Plugins::InsightTimer::API::formatDuration($fav->{duration});
		my $subtitle = $fav->{publisher_name} || '';
		$subtitle .= " ($duration)" if $duration;

		{
			name    => $fav->{title},
			line1   => $fav->{title},
			line2   => $subtitle,
			type    => 'playlist',
			url     => \&itemMenu,
			passthrough => [{
				id             => $fav->{id},
				title          => $fav->{title},
				publisher_id   => $fav->{publisher_id},
				publisher_name => $fav->{publisher_name},
				duration       => $fav->{duration},
				content_type   => $fav->{content_type},
			}],
		};
	} @$favorites ];

	$cb->({ items => $items });
}

sub toggleFavorite {
	my ($client, $cb, $params, $args) = @_;

	my $favorites = $prefs->get('favorites') || [];

	if (_isFavorite($args->{id})) {
		$favorites = [ grep { $_->{id} ne $args->{id} } @$favorites ];
	} else {
		# Add to front, dedup, cap
		unshift @$favorites, {
			id             => $args->{id},
			title          => $args->{title},
			publisher_id   => $args->{publisher_id},
			publisher_name => $args->{publisher_name},
			duration       => $args->{duration},
			content_type   => $args->{content_type},
			added_at       => time(),
		};

		# Dedup by id (keep first = newest)
		my %seen;
		$favorites = [ grep { !$seen{$_->{id}}++ } @$favorites ];

		# Cap
		splice @$favorites, Plugins::InsightTimer::API::MAX_FAVORITES
			if scalar @$favorites > Plugins::InsightTimer::API::MAX_FAVORITES;
	}

	$prefs->set('favorites', $favorites);
	$cb->({ items => [{ nextWindow => 'parent' }] });
}

sub _isFavorite {
	my ($id) = @_;
	my $favorites = $prefs->get('favorites') || [];
	return scalar grep { $_->{id} eq $id } @$favorites;
}

# --- Teachers ---

sub showTeachers {
	my ($client, $cb) = @_;

	my $teachers = $prefs->get('teachers') || [];

	if (!scalar @$teachers) {
		return $cb->({ items => [{
			name => cstring($client, 'PLUGIN_INSIGHTTIMER_NO_TEACHERS'),
			type => 'textarea',
		}] });
	}

	my $items = [ map {
		{
			name => $_->{name},
			type => 'link',
			url  => \&browseList,
			passthrough => [{ publisher_id => $_->{publisher_id}, sort_option => 'popular' }],
		}
	} @$teachers ];

	$cb->({ items => $items });
}

sub toggleTeacher {
	my ($client, $cb, $params, $args) = @_;

	my $teachers = $prefs->get('teachers') || [];

	if (_isFollowing($args->{publisher_id})) {
		$teachers = [ grep { $_->{publisher_id} ne $args->{publisher_id} } @$teachers ];
	} else {
		unshift @$teachers, {
			publisher_id => $args->{publisher_id},
			name         => $args->{publisher_name},
			added_at     => time(),
		};

		my %seen;
		$teachers = [ grep { !$seen{$_->{publisher_id}}++ } @$teachers ];

		splice @$teachers, Plugins::InsightTimer::API::MAX_TEACHERS
			if scalar @$teachers > Plugins::InsightTimer::API::MAX_TEACHERS;
	}

	$prefs->set('teachers', $teachers);
	$cb->({ items => [{ nextWindow => 'parent' }] });
}

sub _isFollowing {
	my ($publisherId) = @_;
	return 0 unless $publisherId;
	my $teachers = $prefs->get('teachers') || [];
	return scalar grep { $_->{publisher_id} eq $publisherId } @$teachers;
}

# --- Recently Played ---

sub showRecent {
	my ($client, $cb) = @_;

	my $recent = $prefs->get('recent') || [];

	if (!scalar @$recent) {
		return $cb->({ items => [{
			name => cstring($client, 'PLUGIN_INSIGHTTIMER_NO_RECENT'),
			type => 'textarea',
		}] });
	}

	my $items = [ map {
		my $r = $_;
		my $duration = Plugins::InsightTimer::API::formatDuration($r->{duration});
		my $subtitle = $r->{publisher_name} || '';
		$subtitle .= " ($duration)" if $duration;

		{
			name    => $r->{title},
			line1   => $r->{title},
			line2   => $subtitle,
			type    => 'audio',
			url     => 'insighttimer://' . $r->{id} . '.mp3',
		};
	} @$recent ];

	$cb->({ items => $items });
}

# Called by ProtocolHandler when a track starts playing
sub addToRecent {
	my ($class, $item) = @_;

	return unless $item && $item->{id};

	my $recent = $prefs->get('recent') || [];

	unshift @$recent, {
		id             => $item->{id},
		title          => $item->{title},
		publisher_name => $item->{publisher_name} || $item->{publisher}{name} || '',
		duration       => $item->{duration} || $item->{media_length},
		played_at      => time(),
	};

	# Cap at MAX_RECENT
	splice @$recent, Plugins::InsightTimer::API::MAX_RECENT
		if scalar @$recent > Plugins::InsightTimer::API::MAX_RECENT;

	$prefs->set('recent', $recent);
}

1;
