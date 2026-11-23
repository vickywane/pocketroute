#!/usr/bin/env python3
"""Stage a built network snapshot into firebase-public/ for Hosting.

Copies the snapshot to its immutable version folder, writes the network
manifest, and makes sure the catalog lists the network. It never overwrites a
published version with different bytes. Deploying is a separate step:

    python3 tools/build_tfl_network.py
    python3 tools/publish_dataset.py
    firebase deploy --only hosting
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_SNAPSHOT = ROOT / "shared/fixtures/london-underground-network-v1.json"
DEFAULT_MANIFEST = ROOT / "shared/fixtures/london-underground-manifest.json"
PUBLIC = ROOT / "firebase-public"
CITY_NAMES = {"gb-london": "London, UK"}
NETWORK_NAMES = {"london-underground": "London Underground"}


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--snapshot", type=pathlib.Path, default=DEFAULT_SNAPSHOT)
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()

    data = args.snapshot.read_bytes()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    snapshot = json.loads(data)

    digest = hashlib.sha256(data).hexdigest()
    if digest != manifest["sha256"] or len(data) != manifest["sizeBytes"]:
        fail("snapshot does not match its manifest (size or SHA-256); rebuild both together")
    if snapshot.get("version") != manifest["version"] or snapshot.get("networkId") != manifest["networkId"]:
        fail("snapshot version or networkId does not match the manifest")
    for key in ("cityId", "networkId", "version"):
        value = manifest.get(key, "")
        if not value or "/" in value or value in (".", ".."):
            fail(f"manifest {key} is not a safe path segment: {value!r}")

    city, network, version = manifest["cityId"], manifest["networkId"], manifest["version"]
    base = f"/datasets/v1/cities/{city}/networks/{network}"
    expected_path = f"{base}/versions/{version}/network.json"
    if manifest["snapshot"] != expected_path:
        fail(f"manifest snapshot path is {manifest['snapshot']!r}, expected {expected_path!r}")

    target = PUBLIC / expected_path.lstrip("/")
    if target.exists():
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            fail(f"{target.relative_to(ROOT)} already exists with different bytes; versions are immutable")
        print(f"version {version} already staged; leaving it unchanged")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(args.snapshot, target)
        print(f"staged {target.relative_to(ROOT)}")

    manifest_path = PUBLIC / base.lstrip("/") / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {manifest_path.relative_to(ROOT)}")

    catalog_path = PUBLIC / "datasets/v1/catalog.json"
    catalog = json.loads(catalog_path.read_text(encoding="utf-8")) if catalog_path.exists() else {"catalogSchemaVersion": 1, "cities": []}
    entry = next((c for c in catalog["cities"] if c["cityId"] == city), None)
    if entry is None:
        entry = {"cityId": city, "displayName": CITY_NAMES.get(city, city), "networks": []}
        catalog["cities"].append(entry)
    if not any(n["networkId"] == network for n in entry["networks"]):
        entry["networks"].append({"networkId": network, "displayName": NETWORK_NAMES.get(network, network),
                                  "manifestPath": f"{base}/manifest.json"})
        catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"added {city}/{network} to the catalog")
    print("Ready. Deploy with: firebase deploy --only hosting")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
