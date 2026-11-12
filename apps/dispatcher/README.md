# dispatcher — the unified Flutter app

One app for every role. The role returned at login picks the tabs (see the root [README](../../README.md#the-app)).

```bash
flutter pub get
flutter run                 # or: flutter run -d linux
flutter analyze && flutter test
flutter build apk           # Android; flutter build linux needs GTK3
```

| Path | What |
|---|---|
| `lib/main.dart` | Entry point, settings load, role-based tabs |
| `lib/auth_service.dart`, `login_screen.dart` | Token login against the registry |
| `lib/core/local_store.dart` | Offline SQLite store and sync outbox (structures, services, breadcrumbs) |
| `lib/core/sync_service.dart` | Push/pull with the registry; records codes the server issues |
| `lib/core/gps_service.dart` | Location fixes for walks and pins |
| `lib/mapper_screen.dart`, `map_view.dart`, `tile_layer.dart` | Field tab: offline map, walk recording, capture |
| `lib/lookup_screen.dart` | Code lookup, route map, dispatch and outcome |
| `lib/inbound_call_screen.dart`, `dashboard_screen.dart`, `map_screen.dart`, `admin_screen.dart` | Dispatcher/admin tabs |
| `lib/more_screen.dart`, `create_dispatch_screen.dart`, `history_screen.dart` | More tab and the screens it opens (manual dispatch, dispatch log, settings) |
| `lib/settings_screen.dart`, `models.dart` | Registry URL, responder start point, theme |
| `lib/design_system.dart`, `components.dart` | Shared UI |
| `tiles/` | Optional offline OSM tiles (`python ../../scripts/download-tiles.py --out tiles`); gitignored apart from `.gitkeep` |

Point the app at the registry in **Settings → Registry API Base URL**. On a phone, that's the laptop's LAN IP, for example `http://192.168.1.20:8090`.
