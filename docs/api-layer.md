# API layer and backend design

## Recommendation

PocketRoute does not need a custom application server for its core route or map download APIs. Keep route search on the iPhone and serve the compiled network as versioned static JSON from Firebase Hosting. Hosting already delivers static files through Firebase's CDN, so inserting a Cloud Function between the app and the same file would add a request hop without adding useful behavior.

Use Cloud Functions only when PocketRoute needs server-side behavior, such as a protected TfL proxy, user accounts or synced data, a personalized response, or scheduled ingestion and publication. Functions are not the map database, and they should not be in the critical offline route-search path.

## Proposed architecture

```text
                    build / release pipeline
TfL open data  ------------------------------> validated JSON snapshot
                                                    |
                                                    v
                                               Firebase Hosting
                                               (global CDN, HTTPS)
                                                    |
                           GET catalog / manifest / versioned snapshot
                                                    |
                                                    v
iOS app: DatasetClient -> verify SHA-256 -> atomic local activation
                                  |
                                  v
                    local NetworkRepository -> local RouteEngine
```

The API layer in the app should be a small transport boundary, not a route-computation backend:

- `DatasetClient` makes HTTPS GET requests and handles timeouts, HTTP errors, and downloads.
- `DatasetManifest` decodes the published manifest and provides the current version, path, size, and checksum.
- `DatasetStore` owns the bundled fallback and downloaded files in the app's Application Support directory.
- `NetworkRepository` exposes the active dataset to search and UI code without exposing file paths or download details.
- `RouteEngine` reads the active local graph and calculates routes deterministically on device.

The iOS Settings screen now has a city/network map menu populated from the Hosting catalog. Selecting an entry fetches its manifest and snapshot; only after checksum and schema validation does the app save it under `Application Support/PocketRoute/Datasets/{cityId}/{networkId}/{version}/network.json` and make that entry active. The station picker, nearby-station suggestion and route search all use the active snapshot. The active file is recorded relative to `Datasets/`, and older versions are deleted after a new one is activated.

Keep these behind protocols so the UI does not depend on URLSession or Firebase. A future provider can change without changing route search.

## Read endpoints

All endpoints are public, read-only static resources on the current Firebase Hosting site:

| Method and path | Purpose | Cache behavior |
| --- | --- | --- |
| `GET /datasets/v1/catalog.json` | Lists supported city/network identifiers and manifest paths | 5 minutes |
| `GET /datasets/v1/cities/{cityId}/networks/{networkId}/manifest.json` | Points to the latest published immutable snapshot and gives its version, byte count, and SHA-256 | 5 minutes |
| `GET /datasets/v1/cities/{cityId}/networks/{networkId}/versions/{version}/network.json` | Full immutable network payload | 1 year, immutable |

Current London example: `cityId=gb-london`, `networkId=london-underground`. Version paths must never be overwritten with different bytes. Publish a new version directory for every changed snapshot, then update the manifest to point at it.

## iOS synchronization flow

1. On launch, load the bundled dataset or the last verified downloaded dataset immediately. Route search stays available offline.
2. When online, fetch the network manifest with a short timeout. The manifest is small and may be cached briefly.
3. If its version equals the active version, stop. Otherwise download the manifest's versioned snapshot to a temporary file.
4. Check the downloaded byte count and SHA-256 against the manifest. Decode and validate the schema version and required identifiers.
5. Only after all checks pass, move the file into the app's data directory and atomically mark that version active. Keep the previous verified copy until activation succeeds.
6. If any step fails, keep using the prior local copy and retry on a later online session. Never make route search wait for a download.

The app should use HTTPS and normal URLSession caching. The static payload is public data; no user token or Firebase Auth session is needed to download it. The checksum detects corruption or a mismatched deployment, but it is not a signature proving who published the file. If the threat model later requires publisher authenticity, sign the manifest in the release pipeline and verify that signature in the app.

## What belongs in Firebase Cloud Functions?

Not in the first version:

- Serving the static map snapshot or manifest.
- Route calculation, station lookups, or local graph traversal.
- A proxy that simply returns public TfL data already compiled into the snapshot.

Potential later Functions:

- A scheduled ingestion job that fetches TfL data, validates it, and publishes a new immutable version plus manifest. Keep credentials and publication permissions on the server/build runner, never in the iOS app.
- An HTTPS endpoint for live disruptions, if PocketRoute adds live data and needs normalization, caching, or a protected upstream credential. Treat that response as optional; offline routing must still work.
- Authenticated user features, such as syncing saved preferences across devices. Store those separately from the public network dataset.

For now, compilation is an explicit maintainer/build task using `tools/build_tfl_network.py`; deployment to Hosting is a separate release action. This makes dataset changes reviewable and avoids deploying a backend that the app does not need.

## API versioning rules

- `/datasets/v1/` versions the URL and payload contract. Make breaking contract changes under `/datasets/v2/` while clients transition.
- `schemaVersion` identifies the JSON structure; `version` identifies the particular dataset build. A data refresh can change `version` without changing `schemaVersion`.
- Keep old versioned snapshots available while installed app versions might still refer to them. The manifest selects the current version.
- The client must reject unsupported schema versions and retain its last known-good dataset.

## Firebase references

- [Firebase Hosting](https://firebase.google.com/docs/hosting/) serves static content over HTTPS from a global CDN and can be combined with backend services when dynamic behavior is needed.
- [Hosting cache behavior](https://firebase.google.com/docs/hosting/manage-cache) describes CDN and browser caching for static resources.
- [Cloud Functions for Firebase](https://firebase.google.com/docs/functions) runs backend code in response to HTTPS requests, events, or scheduled jobs.
