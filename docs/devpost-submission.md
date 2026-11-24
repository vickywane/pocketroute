# Devpost submission: PocketRoute

Copy each section into the matching Devpost field.

## Tagline

Re-route your Tube journey with no signal. Describe what went wrong and get another way to your destination.

## Platforms

iOS and Web (Chrome).

## Inspiration

Deep-level Tube stations and tunnels often have no usable signal. When a train is held, terminates early or a line closes, Citymapper, Google Maps and TfL Go can't refresh, and passengers fall back on station maps or asking strangers. PocketRoute is the thing you open when your plan breaks and you can't get online to fix it.

## What it does

- Keeps an offline copy of the Tube network (stations, lines, branches, interchanges, walking links), published as a versioned dataset on Firebase Hosting and refreshed whenever there's a connection.
- The passenger taps or types what happened in plain English: "Held at Camden on the Northern, need Warren St".
- A model turns the message into typed fields (stations, line, situation, closures, step-free, walking). Every name is checked against the saved map, and anything the passenger didn't say is dropped.
- A deterministic route engine searches the offline graph and returns ranked route cards: fastest, fewest changes, walk.
- Follow-ups are one tap or one sentence ("the Charing Cross branch isn't running", "step-free only"), and step-by-step guidance has a "find another way" button that re-routes from where you are.
- Ambiguous stations become a question with choices. Questions about live service get an honest "I can't see that offline".

## How we used Firebase AI Logic

The model reads the passenger's words. The saved map and the route engine supply every fact.

- **iOS:** Apple Foundation Models runs on device first. When the passenger has opted in and is online, Gemini (`gemini-3.1-flash-lite`) is the fallback. On iOS 27 both run through a Foundation Models `LanguageModelSession` with `@Generable` output, with Gemini supplied by Firebase AI Logic's `geminiLanguageModel(name:)`. Code: `apps/ios/PockerRouter/AI/OnDeviceParser.swift`, `CloudParser.swift`, `RerouteAssistant.swift`.
- **Web:** `getGenerativeModel` with `InferenceMode.PREFER_ON_DEVICE` runs Chrome's built-in Gemini Nano, with Gemini in the cloud as the fallback. The same JSON schema constrains both, and `inferenceSource` tells the UI which one answered. Code: `apps/web/firebase-ai.js`.
- **Grounding:** every model reading goes through the same checks. Stations and lines the passenger never mentioned are removed, and over-eager flags (a closure they didn't report) are dropped. Each message shows who understood it: on device, Gemini, or keywords.
- **App Check** protects the Gemini calls (DeviceCheck on iOS, reCAPTCHA Enterprise on web, debug providers in development; debug tokens are used for judging).
- **Remote Config** (`assistant_cloud_enabled`, `assistant_cloud_model`) switches Gemini off or changes the model without a release.
- **Hosting** serves the PWA and the versioned Tube map dataset.

If no model can run, keyword rules and the tap flow still work end to end with no network.

## Measured

`shared/fixtures/assistant-eval.json` holds 30 labelled passenger messages, scored field by field. A station the passenger didn't mention counts as a failure.

| Reader | Score |
| --- | --- |
| Keyword rules | 29/30 |
| Apple Intelligence on device, with grounding | 29/30 (22/30 before the grounding rules) |
| Gemini through Firebase AI Logic, with grounding | 29/30 |

## Challenges

- Small on-device models are eager to help: they "correct" station names and invent closures. The fix was to keep the model to reading and never let it decide a fact, plus grounding rules measured against the eval set.
- Firebase AI Logic's iOS API moved during the hackathon (SDK 13 replaced the interim hybrid types with `GeminiLanguageModel` for Apple's Foundation Models framework). The app now uses one Foundation Models session for both models. Apple's `@Generable` schema reaches Gemini with every field required, which first dropped Gemini to 11/30 (it filled in "held" for every message); a Gemini-specific type with explicit "none" choices brought it to 29/30.
- TfL's open data has no timetabled run times, so ride times are estimated from distance at each line's typical speed, plus dwell, boarding and change times. Both apps share the same constants and tests.

## What we built during the hackathon

Everything in this repository was built between 11 and 30 November 2026: the TfL network dataset builder, both route engines, the iOS app, the PWA, the AI reading and grounding layer, the eval set and the Figma designs. No code from before the hackathon is included. Third-party code: Firebase SDKs (iOS and web). Map data: TfL Open Data, Open Government Licence v3.0.

## Try it

- PWA: https://pocketroute-pwa.web.app. Open it once with signal, then turn on Airplane mode. In Chrome with the built-in model enabled, reading happens on device. Otherwise turn on Gemini in Settings → Assistant.
- iOS: build from `apps/ios` (instructions in the README). Needs iOS 26+; Apple Intelligence for on-device reading.

## Demo video plan (under 3 minutes)

1. 0:00–0:15. The problem: a train held underground with no signal.
2. 0:15–0:45. iPhone in Airplane mode: "Held at Camden on the Northern, need Warren St". Show "Understood on this iPhone" and the three route cards.
3. 0:45–1:15. Follow-up: "The Charing Cross branch isn't running". Open step-by-step and tap "find another way".
4. 1:15–1:40. A station-name question ("Edgware Road") turns into choices; a live-status question gets the offline answer.
5. 1:40–2:10. PWA in Chrome, offline: the same flow with Chrome's on-device model.
6. 2:10–2:40. Back online with Gemini turned on: the message shows "Understood by Gemini". Briefly show the Remote Config switch.
7. 2:40–3:00. The AI boundary diagram from the README and the eval scores.
