# CLAUDE.md

## What This Is

A Perl plugin for Logitech Media Server (LMS/Squeezebox) that integrates Insight Timer's public meditation content library. Supports guided meditations, music, and talks. No account required — uses IT's public API.

## Architecture

All modules live under `Plugins::InsightTimer::` namespace. Entry point: `Plugin.pm`.

### Module Relationships

```
Plugin.pm (OPML menus, search, browse, favorites, recent, teachers)
├── API.pm (constants, async HTTP, response normalization)
├── ProtocolHandler.pm (insighttimer:// URI scheme, stream resolution)
└── Settings.pm (preferences UI)
```

### Key Patterns

- **Callback-based async**: All API methods take `($cb, $args)` — callback fires with results
- **OPML feed handlers**: Plugin.pm methods return `{ items => [...] }` structures via callback
- **Preferences**: `Slim::Utils::Prefs` with `preferences('plugin.insighttimer')`
- **Cache**: `Slim::Utils::Cache` with namespace `insighttimer`
- **No auth**: IT's filter and library item APIs are public, no keys needed

### API Endpoints

- Filter: `https://filtering.insighttimer-api.net/api/v1/single-tracks/filter` — search + browse
- Detail: `https://libraryitems.insighttimer.com/{id}/data/libraryitem.json` — full metadata + streams
- Streams: `standard_media_paths` (direct MP3 URLs), `media_paths` (HLS)

### Audio Format

All content is served as MP3 via `standard_media_paths` (direct URLs) or HLS via `media_paths`. Plugin defaults to HLS (higher quality) with MP3 fallback configurable in Settings for older Squeezebox hardware.

## Build & Release

No build system. Pure Perl distributed as ZIP via GitHub Actions.

## File Conventions

- `strings.txt` — Multi-language localization (tab-delimited key/value blocks)
- `HTML/EN/plugins/InsightTimer/` — Web UI templates
- `install.xml` — Plugin manifest
- `repo/repo.xml` — Distribution repository metadata
