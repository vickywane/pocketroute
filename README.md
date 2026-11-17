# PockerRouter

An AI-powered re-routing assistant for London Underground passengers who suddenly lose signal. When a train is held, terminates early, or a line closes while you are underground, PockerRouter helps you work out another way to your destination, even with no mobile data.

PockerRouter is not a replacement for Citymapper, Google Maps or TfL Go. You plan your journey however you normally do. PockerRouter is the thing you open when that plan breaks and you can't get online to fix it.

## The problem

Deep-level Tube stations and tunnels often have no usable signal. If your train stops unexpectedly, the apps you planned with can't refresh, and you are left reading station maps or asking strangers.

**Example:** you are on a Northern line train to Morden via Bank. It stops and is held at Camden Town. You need to get to Warren Street. With no signal, PockerRouter can tell you:

1. **Change to the Charing Cross branch** at Camden Town. Mornington Crescent, Euston, then Warren Street (3 stops).
2. **Stay on one stop to Euston**, then take the Victoria line southbound one stop to Warren Street.
3. **Walk** about 2 km (roughly 27 minutes) if you would rather leave the station.

If you reply "the Charing Cross branch isn't running", it drops that option and walks you through the Euston plan step by step.

## How it works

1. **Before you need it:** the app keeps an offline copy of the Tube network on the device (stations, lines, branches, interchanges and walking links). It refreshes whenever you have a connection.
2. **When something goes wrong:** you tell the app what happened by tapping (where you are, where you are going, what happened) or by typing or speaking in plain English.
3. **AI understands, the route engine decides:** an on-device model turns your message into a structured request (current station, destination, the line you were on, and things to avoid such as a closed branch or step-free needs). A deterministic route engine then searches the offline network graph for alternatives.
4. **Clear, tappable answers:** options appear as large route cards ranked by time and changes. Picking one starts big, glanceable step-by-step guidance with an "I'm on the train" confirmation and a "Something's wrong, find another way" button that re-routes from where you are.

## Design principles

- **Built for stress and one hand.** Large tap targets (56pt+), short sentences, and quick-reply chips instead of typing.
- **Conversation, not menus.** The chat is the core interface. Every follow-up ("train's moving again", "step-free only") is a single tap.
- **No signal assumed.** Every screen works offline. Voice input uses on-device speech recognition.
- **Honest about limits.** The app never claims to know live disruptions. Answers are labelled as coming from the saved Tube map, and the user's own report ("branch isn't running") is treated as the source of truth for current conditions.
- **Location without GPS.** Underground, the app suggests the last station where your phone had signal and lists stations on your line in order, so you can confirm where you are in one tap.

## Core screens

See the [Figma designs](https://www.figma.com/design/Dv7XuIlwLCy33X7GQewOV2/PocketRoute?node-id=26-2) (row "Redesign — offline re-routing assistant").

1. **Stuck underground:** confirm where you are, where you are going and what happened, then "Find another way". Or just describe it.
2. **AI suggests routes:** the assistant replies with ranked route cards (fastest, fewest changes, walk).
3. **Follow-up re-route:** one-tap replies refine the plan, and the assistant returns an updated route.
4. **Step-by-step:** one large instruction at a time, with progress and a re-route escape hatch.
5. **Where are you?:** a station picker ordered along your line, starting from your last known station.

## MVP scope

- Native iOS app first, targeting iOS 26+ for Apple Foundation Models.
- Offline network graph of the Tube (stations, lines, branches, interchanges, walking transfers) bundled with the app and refreshed when online. Use a properly licensed source (for example TfL open data) and record its version and retrieval date.
- AI is used only to understand the user's situation and to phrase answers. Stations, lines, directions, stop counts and routes always come from the local network graph. The model must not invent stations, platforms, disruptions or live service information.
- Firebase AI Logic hybrid inference: Apple Foundation Models on device, with Gemini cloud fallback when a connection is available. If neither model can run, the tap-based flow (station picker, situation tiles, route cards) still works.
- `shared/fixtures/demo-journey.json` is illustrative. A compiled TfL network snapshot is also present, but neither client currently routes against it.

## Repository layout

- `apps/ios`: SwiftUI iOS app and XcodeGen project spec.
- `apps/web`: installable, offline-shell PWA prototype (voice input omitted).
- `shared/contracts`: versioned data contracts (journey and network snapshots).
- `shared/fixtures`: demo journey plus a compiled TfL Underground network snapshot and update manifest.
- `docs`: architecture, data provenance, and setup notes.

See [API layer and backend design](docs/api-layer.md) for the proposed app data API, Firebase Hosting endpoints, iOS synchronization flow, and when Cloud Functions would be warranted. See [London network data](docs/london-network-data.md) for the dataset source, build process, published Hosting paths, and refresh procedure.

The compiled TfL Tube network snapshot and reproducible builder are in `shared/fixtures/london-underground-network-v1.json` and `tools/build_tfl_network.py`. The iOS app downloads the selected city map from Firebase Hosting and uses its stations in the station picker, but route calculations and displayed route choices remain illustrative. The PWA is still demo-only. See [London network data](docs/london-network-data.md) for source, attribution, coverage and rebuild instructions.

## Run the PWA prototype

Serve the static client on localhost (required for service workers and location permissions):

```sh
cd apps/web
python3 -m http.server 4173
```

Open `http://localhost:4173` in a browser. In supported browsers, use the browser's install action to add PocketRoute to the home screen. The PWA caches its application shell for offline reopening; the current demo route data is illustrative only.

## Project links

- [Figma designs](https://www.figma.com/design/Dv7XuIlwLCy33X7GQewOV2/PocketRoute?node-id=26-2): offline re-routing flow.
- [Linear project brief](https://linear.app/victory-engineering/issue/VIC-118/build-tubeoffline-offline-first-london-tube-journey-companion): original scope and implementation notes.

## Firebase setup

1. The Firebase project is `pockerrouter-2026` (account `vickywane@gmail.com`), with the iOS bundle ID `dev.pockerrouter.ios` already registered. `.firebaserc` selects this project by default, and Firebase AI Logic has been provisioned.
2. Download or retrieve that app's `GoogleService-Info.plist` into `apps/ios/PockerRouter/Resources/`. The file is gitignored and copied into the app bundle by the Xcode build script.
3. Configure App Check for the iOS app in the Firebase console. The app uses the debug provider in Debug builds; register its generated debug token for local testing. Never commit debug tokens. Configure App Attest or DeviceCheck for production.
4. Open the generated `apps/ios/PockerRouter.xcodeproj` in Xcode, select a physical Apple Intelligence-capable iPhone, and run.
5. Generate the Xcode project with `cd apps/ios && xcodegen generate` after changing `project.yml`.

The scaffold does not include Firebase credentials, production App Check attestation, a TfL network data integration, or a claim that the demo fixture represents a valid route.
