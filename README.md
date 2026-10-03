# Simple Financial Planner

**How much runway is left, and what did today actually cost?**

A standalone, offline-first Flutter app. Install it, set a balance and a daily
budget, log expenses — it works with no account and no server. An optional
self-hosted sync endpoint can be injected at build time
(`--dart-define=API_BASE=...`); when it is unreachable the app falls back
silently to the on-device ledger instead of showing an error.

---

## Screenshots

| Empty state | Runway | Today |
|---|---|---|
| ![Empty state](screenshots/empty-state.png) | ![Runway](screenshots/home-runway.png) | ![Today](screenshots/today-budget.png) |

## The number that changes behaviour

A balance tells you what you have. **Runway** tells you what to do about it.

So the headline is not the balance — it is `days remaining at current burn`.
Balance sits underneath as context. A balance of 3,500,000 reads as comfortable;
"9 days" reads as urgent, and only one of those makes you act.

Under a week, it turns red and says so.

## What it shows

- **Runway** — days left at the current average daily burn
- **Today** — spent vs daily budget, with what is left free
- **Last 30 days** — total spend, average per day
- **Your plan** — balance and daily budget, editable on-device
- **Log an expense** — amount and an optional note

Until you log spending there is no honest burn rate, so the app says
"No spending logged yet" instead of inventing a figure.

## Home-screen widget

A native Android widget (`RunwayWidget`) shows days of runway and what is left
free today — without opening the app.

## Offline-first, optional sync

The ledger lives in `SharedPreferences` via `lib/local_store.dart`, so the app
is fully usable with no connectivity. When a sync server is configured, the app
tries it first with a short timeout and syncs expenses best-effort; any
failure falls back silently to local data. An unreachable server is the normal
case for a fresh install, not an error worth a red card.

## Runway maths

Pure functions in `lib/finance_math.dart`, unit-tested in CI without a device
or a server:

```
avg_daily   = total_spent_30d / days_with_spend
runway_days = balance / avg_daily
```

With no spending there is no honest burn rate, so `runway_days` is omitted and
the UI renders "No spending logged yet".

## Build

```bash
flutter pub get
flutter test
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

With optional sync:

```bash
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --dart-define=API_BASE=https://your-host \
  --dart-define=API_KEY=your-key
```

CI (GitHub Actions) builds and tests on every push to `main`. The native
widget reads its endpoint from string resources, so CI injects `API_BASE` /
`API_KEY` into `strings.xml` **before** the build step.

## Privacy

Everything is stored on the device by default. No account, no tracking. If you
point the app at your own server, your data goes only there.

## Not a licensed advisor

This app **computes and reports**. It does not recommend trades or investments.

## Licence

MIT
