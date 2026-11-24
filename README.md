# PocketRoute

An AI-powered re-routing assistant for London Underground passengers who suddenly lose signal. When a train is held, terminates early, or a line closes while you are underground, PocketRoute helps you work out another way to your destination, even with no mobile data.

PocketRoute is not a replacement for Citymapper, Google Maps or TfL Go. You plan your journey however you normally do. PocketRoute is the thing you open when that plan breaks and you can't get online to fix it.

- **Live PWA:** https://pocketroute-pwa.web.app
- **iOS app:** SwiftUI, iOS 26+ (`apps/ios`)

## The problem

Deep-level Tube stations and tunnels often have no usable signal. If your train stops unexpectedly, the apps you planned with can't refresh, and you are left reading station maps or asking strangers.

**Example:** you are on a Northern line train to Morden via Bank. It stops and is held at Camden Town. You need to get to Warren Street. Type or say *"Held at Camden on the Northern, need Warren St"* and, with no signal, PocketRoute replies with:

1. **Change to the Charing Cross branch** at Camden Town. Mornington Crescent, Euston, then Warren Street (3 stops).
2. **Stay on one stop to Euston**, then take the Victoria line southbound one stop to Warren Street.
3. **Walk** about 2 km (roughly 26 minutes) if you would rather leave the station.

If you reply "the Charing Cross branch isn't running", it drops that option and walks you through the Euston plan step by step.

## How it works

1. **Before you need it:** the app keeps an offline copy of the Tube network (stations, lines, branches, interchanges, walking links), published as a versioned dataset on Firebase Hosting and refreshed whenever there's a connection.
2. **When something goes wrong:** you tell the app what happened by tapping (where you are, where you're going, what happened) or by typing or speaking in plain English.
3. **AI understands, the route engine decides:** a model turns your message into typed fields (stations, line, closures, step-free, walking). Every name is matched against the saved map, and anything you didn't actually say is dropped. A deterministic route engine then searches the offline graph.
4. **Clear, tappable answers:** ranked route cards, one-tap follow-ups, and step-by-step guidance with a "Something's wrong, find another way" button that re-routes from where you are.

## Firebase

| Product | What it does here |
| --- | --- |
| **Firebase AI Logic** | Hybrid inference. iOS: Apple Foundation Models on device, then Gemini (`gemini-3.1-flash-lite`) when the passenger has opted in and is online. On iOS 27 both run through one Foundation Models `LanguageModelSession` with `@Generable` output, with Gemini supplied by Firebase AI Logic's `geminiLanguageModel(name:)`; iOS 26 calls Gemini's `generateContent` with a matching JSON schema. Web: `InferenceMode.PREFER_ON_DEVICE` runs Chrome's built-in model in the browser, with Gemini as the cloud fallback. Every reader returns schema-constrained structured output. |
| **Remote Config** | `assistant_cloud_enabled` switches Gemini off and `assistant_cloud_model` changes the model, without an app release. |
| **App Check** | Protects the Gemini calls. iOS: debug provider in Debug builds, DeviceCheck in release. Web: reCAPTCHA Enterprise (`APP_CHECK_SITE_KEY` in `apps/web/firebase-ai.js`), with the debug provider on localhost. |
| **Hosting** | Two sites: the PWA (`pocketroute-pwa`) and the versioned Tube map dataset (`pockerrouter-2026`), with short-cache manifests and immutable dataset versions. The PWA reads its Firebase config from Hosting's `/__/firebase/init.json`, so no keys are committed. |

Re-routing never depends on the network. If no model can run, keyword rules and the tap-based flow still work end to end.

## The AI boundary

The model reads the passenger's words. The saved map and the route engine supply every fact.

```
passenger's words
  → interpret   (Apple Intelligence · Chrome's model · Gemini · keyword rules)   → names and flags
  → ground      (drop any station or line the passenger never said)
  → plan        (match names to the saved map; ask with one-tap choices if unsure)
  → route       (deterministic Dijkstra over the saved map)
  → reply       (sentences built from map data; the model writes none of them)
```

Ambiguous stations ("Edgware Road") become a question with choices, never a guess. Questions about live service, delays or platforms get an honest "I can't see that offline". See [AI interaction](docs/ai-interaction.md).

### Measured

`shared/fixtures/assistant-eval.json` holds 30 labelled passenger messages. Both clients score every reader against it, field by field, and a station the passenger didn't mention counts as a failure.

| Reader | Score |
| --- | --- |
| Keyword rules (iOS and web, every device) | 29/30 |
| Apple Intelligence on device, with grounding (iOS simulator) | 29/30 (22/30 before the trust rules) |
| Gemini through Firebase AI Logic (`GeminiLanguageModel` in a Foundation Models session), with grounding | 29/30 |

Run the Gemini evaluation with `TEST_RUNNER_POCKETROUTE_EVAL_GEMINI=1` (see Tests). The Apple Intelligence evaluation runs automatically wherever the model is available, including the simulator on an Apple Intelligence Mac.

## Design principles

- **Built for stress and one hand.** Large tap targets (56pt+), short sentences, and quick-reply chips instead of typing.
- **Conversation, not menus.** The chat is the core interface. Every follow-up ("train's moving again", "step-free only") is a single tap.
- **No signal assumed.** Every screen works offline. Voice input uses on-device speech recognition.
- **Private by default.** Messages leave the device only if the passenger turns on Gemini in Settings.
- **Honest about limits.** The app never claims to know live disruptions. The user's own report ("branch isn't running") is treated as the source of truth for current conditions.
- **Location without GPS.** Underground, the app suggests the last station where your phone had a fix and lists stations on your line in order, so you can confirm where you are in one tap.

## Core screens

See the [Figma designs](https://www.figma.com/design/Dv7XuIlwLCy33X7GQewOV2/PocketRoute?node-id=26-2) (row "Redesign — offline re-routing assistant").

1. **Stuck underground:** confirm where you are, where you're going and what happened, then "Find another way". Or just describe it.
2. **AI suggests routes:** ranked route cards (fastest, fewest changes, walk), with what was understood shown under your message.
3. **Follow-up re-route:** one-tap replies or free text refine the plan.
4. **Step-by-step:** one large instruction at a time, with progress and a re-route escape hatch.
5. **Where are you?:** a station picker ordered along your line, starting from your last known station.

## Route estimates

The TfL source has no timetabled run times, so ride times are estimated from distance at each line's typical running speed (faster on the Metropolitan, Jubilee and Victoria lines, slower on the Circle and Hammersmith & City), plus dwell, boarding and change times. The two engines (`apps/ios/PockerRouter/Routing/RouteEngine.swift`, `apps/web/route-engine.js`) share the same constants and tests.

## Repository layout

- `apps/ios`: SwiftUI iOS app and XcodeGen project spec. Product name PocketRoute; the Xcode target and bundle ID keep the original `PockerRouter` / `dev.pockerrouter.ios`.
- `apps/web`: installable offline PWA (no voice input).
- `shared/contracts`: versioned network snapshot contract.
- `shared/fixtures`: compiled TfL Underground snapshot, update manifest, and the assistant evaluation set.
- `tools`: dataset builder, publisher, PWA build and local server.
- `docs`: [architecture](docs/architecture.md), [AI interaction](docs/ai-interaction.md), [API layer](docs/api-layer.md), [London network data](docs/london-network-data.md).

## Run the PWA

```sh
python3 tools/serve_web.py
```

Open `http://127.0.0.1:4173`. The service worker caches the app shell, the Tube map and the Firebase SDK for offline use. Bump `CACHE_VERSION` in `apps/web/sw.js` when the list of shell files changes.

Gemini in the PWA uses the "PocketRoute Web" Firebase app. On Hosting, the keys come from `/__/firebase/init.json` and the app ID from `firebase-ai.js`. Locally, write the config to the gitignored `apps/web/firebase-config.json`:

```sh
npx firebase-tools apps:sdkconfig WEB 1:70786883109:web:4ea32be141ac9f57baa9cc --json | python3 -c "import json,sys;json.dump(json.load(sys.stdin)['result']['sdkConfig'],open('apps/web/firebase-config.json','w'),indent=2)"
```

Without a config, the PWA uses Chrome's on-device model where available and keyword rules otherwise. Turn on Gemini in Settings → Assistant.

## Deploy the PWA

```sh
npx firebase-tools deploy --only hosting:pocketroute-pwa
```

The predeploy step runs `tools/build_web.py`, which copies `apps/web` into `build/web` with the real Tube map in place of the `apps/web/data/` symlink. `firebase.json` serves `/`, `index.html`, `sw.js` and the manifest with `Cache-Control: no-cache`.

Use `npx firebase-tools` rather than a standalone `firebase` binary built for Intel if you're on Apple silicon.

### Install on a phone

1. Open https://pocketroute-pwa.web.app.
2. **iPhone (Safari):** Share → **Add to Home Screen**. **Android (Chrome):** menu → **Install app**.
3. Open it once with signal so it saves the app and the Tube map, then try it in Airplane mode.

## Tests

```sh
cd apps/ios && xcodegen generate && xcodebuild test -project PockerRouter.xcodeproj -scheme PockerRouter -destination 'platform=iOS Simulator,name=iPhone 17'
```

```sh
node --test apps/web/*.test.mjs
```

Add the live Gemini evaluation to the iOS run (needs network and `GoogleService-Info.plist`):

```sh
cd apps/ios && TEST_RUNNER_POCKETROUTE_EVAL_GEMINI=1 xcodebuild test -project PockerRouter.xcodeproj -scheme PockerRouter -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PockerRouterTests/AssistantEvalTests
```

## Firebase setup

1. The Firebase project is `pockerrouter-2026`, with an iOS app (`dev.pockerrouter.ios`) and a web app ("PocketRoute Web") registered. `.firebaserc` selects it by default. Firebase AI Logic uses the Gemini Developer API.
2. Put the iOS app's `GoogleService-Info.plist` in `apps/ios/PockerRouter/Resources/`. It's gitignored and copied into the bundle by the build script. Without it, Firebase stays off and the app uses on-device and keyword reading only.
3. App Check: Debug builds use the debug provider; register the generated debug token in the console. Release builds use DeviceCheck. Never commit debug tokens.
4. Remote Config: optional. The app ships with defaults for `assistant_cloud_enabled` (true) and `assistant_cloud_model`.
5. Regenerate the Xcode project with `cd apps/ios && xcodegen generate` after changing `project.yml`.

## Project links

- [Figma designs](https://www.figma.com/design/Dv7XuIlwLCy33X7GQewOV2/PocketRoute?node-id=26-2)
- [Linear project brief](https://linear.app/victory-engineering/issue/VIC-118/build-tubeoffline-offline-first-london-tube-journey-companion)

## Licence

Apache License 2.0. See [LICENSE](LICENSE).

Map data: TfL Open Data, Open Government Licence v3.0. Route times are estimates from the static map, not live service information.
