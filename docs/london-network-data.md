# London Underground network data

## Build the offline snapshot

The source data is retrieved from TfL's Unified API and compiled into the stable PocketRoute contract at `shared/contracts/london-underground-network-v1.schema.json`.

```sh
python3 tools/build_tfl_network.py
```

The outputs are `shared/fixtures/london-underground-network-v1.json` and `shared/fixtures/london-underground-manifest.json`. To supply TfL API credentials, set `TFL_APP_ID` and `TFL_APP_KEY` in the shell or pass `--app-id` and `--app-key`. Do not commit credentials. The builder waits briefly between API requests, retries transient throttling/server errors, verifies referential integrity, then atomically replaces the output files. The manifest includes the versioned Firebase Hosting path, byte size, SHA-256 checksum and coverage summary.

## Data represented

- All Tube lines and TfL ordered route paths in both directions, including regular and Night Tube service variants when TfL returns them.
- Station identifiers, public names, coordinates, fare zone, TfL hub code, and line memberships.
- Directed adjacent-station segments suitable for graph search. Interchange groups use shared TfL station IDs and TfL hub codes; transfer duration is left unknown instead of guessed.
- The current [TfL detailed station-topology archive](https://api.tfl.gov.uk/stationdata/tfl-stationdata-detailed.zip): platforms, Tube platform service/access data, station points, step-free paths (level, ramp, lift), lift notes and the supplied step-free platform interchange distances. Platform-level street accessibility is labelled `available`, `no-recorded-path`, or `unknown`, based on TfL's own coverage flag and pathway graph.
- TfL's `AccessViaLift` station attribute is preserved as supplied, but platform accessibility comes from the detailed topology. The archive provenance and SHA-256 are recorded in the snapshot.

## Deliberate limits

This is static network topology, not a live service feed. The station topology archive is refreshed quarterly and does not tell the app whether a lift is currently out of service; use current TfL lift/disruption information before presenting a step-free journey as available. There are no walking links between separate stations or source-provided train run times. Transfer durations remain unknown, so the route engines estimate ride time from distance (about 33 km/h plus dwell) and add fixed waits for boarding (4 min) and changes (5 min). The apps label these as estimates.

## Attribution and terms

The snapshot carries the attribution `Powered by TfL Open Data`. TfL states that public-sector information from its website and Unified API is generally under the Open Government Licence v3.0; other source datasets can have their own terms. Review the current [TfL Transport Data Service terms](https://tfl.gov.uk/corporate/terms-and-conditions/transport-data-service) and record provenance for each additional dataset before release.

## Update/deployment flow

Regenerate this artifact from a trusted build environment, review the provenance/coverage metadata and route-count changes, then stage it with `python3 tools/publish_dataset.py` and deploy with `npx firebase-tools deploy --only hosting:pockerrouter-2026` (the data site; the PWA is a separate site). The staging script checks the snapshot against its manifest, copies it to its immutable version folder, refuses to overwrite an existing version with different bytes, and adds the network to the catalog. Publish a small `manifest.json` separately; the iOS client downloads the manifest, fetches a versioned snapshot, verifies its checksum, and only then activates it. Bundle a known-good snapshot with the app so first launch and failed updates still work offline.

## Published Firebase Hosting files

The current Hosting site is `pockerrouter-2026.web.app`. Static data is stored in the Hosting deployment directory `firebase-public/`, not in Firestore or Cloud Storage. Hosting serves these files over HTTPS through its CDN.

- Catalog: `firebase-public/datasets/v1/catalog.json` → `/datasets/v1/catalog.json`
- Current London manifest: `firebase-public/datasets/v1/cities/gb-london/networks/london-underground/manifest.json` → `/datasets/v1/cities/gb-london/networks/london-underground/manifest.json`
- Versioned snapshot: `firebase-public/datasets/v1/cities/gb-london/networks/london-underground/versions/{version}/network.json`
- Build output before staging: `shared/fixtures/london-underground-network-v1.json`

`firebase.json` sets the Hosting public directory and cache headers. The catalog and current manifest are cached for 5 minutes so a publication becomes visible soon. Versioned snapshot files are cached for one year as immutable; never replace a file at an existing version URL. Publish new snapshot bytes under a new version path, then update the manifest and catalog if needed. The manifest checksum and size let the app reject incomplete or mismatched downloads.

The currently published version is `20261117-191431`. Its download URL is `https://pockerrouter-2026.web.app/datasets/v1/cities/gb-london/networks/london-underground/versions/20261117-191431/network.json`. See [API layer and backend design](api-layer.md) for the client sync sequence and the criteria for adding Cloud Functions.
