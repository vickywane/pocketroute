#!/usr/bin/env python3
"""Build PocketRoute's versioned London Underground network from TfL Unified API."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import io
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

API_BASE = "https://api.tfl.gov.uk"
USER_AGENT = "PocketRouteNetworkBuilder/1.0 (TfL open-data attribution: Powered by TfL Open Data)"
DEFAULT_OUTPUT = pathlib.Path("shared/fixtures/london-underground-network-v1.json")
DEFAULT_MANIFEST = pathlib.Path("shared/fixtures/london-underground-manifest.json")
TOPOLOGY_URL = "https://api.tfl.gov.uk/stationdata/tfl-stationdata-detailed.zip"


def fetch_json(path: str, app_id: str | None, app_key: str | None) -> object:
    query: dict[str, str] = {}
    if app_id:
        query["app_id"] = app_id
    if app_key:
        query["app_key"] = app_key
    url = f"{API_BASE}{path}"
    if query:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query)
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": USER_AGENT},
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            if error.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(2**attempt)
                continue
            raise RuntimeError(f"TfL API returned HTTP {error.code} for {path}: {detail}") from error
        except (TimeoutError, urllib.error.URLError) as error:
            if attempt < 3:
                time.sleep(2**attempt)
                continue
            raise RuntimeError(f"Could not fetch {path}: {error}") from error
    raise RuntimeError(f"Could not fetch {path}")


def fetch_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"Accept": "application/zip", "User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(2**attempt)
                continue
            raise RuntimeError(f"TfL topology download returned HTTP {error.code}") from error
        except (TimeoutError, urllib.error.URLError) as error:
            if attempt < 3:
                time.sleep(2**attempt)
                continue
            raise RuntimeError(f"Could not fetch TfL station-topology archive: {error}") from error
    raise RuntimeError("Could not fetch TfL station-topology archive")


def props_by_key(record: dict) -> dict[str, str]:
    return {
        str(item.get("key")): str(item.get("value"))
        for item in record.get("additionalProperties", [])
        if item.get("key") is not None and item.get("value") is not None
    }


def read_csv_archive(archive: zipfile.ZipFile, name: str) -> list[dict[str, str]]:
    try:
        content = archive.read(name).decode("utf-8-sig")
    except KeyError as error:
        raise RuntimeError(f"TfL detailed station archive is missing {name}") from error
    return list(csv.DictReader(io.StringIO(content)))


def station_id(record: dict) -> str | None:
    return record.get("stationNaptan") or record.get("naptanId") or record.get("id")


def clean_station_name(name: str) -> str:
    suffix = " Underground Station"
    return name[: -len(suffix)] if name.endswith(suffix) else name


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--app-id", default=os.getenv("TFL_APP_ID"))
    parser.add_argument("--app-key", default=os.getenv("TFL_APP_KEY"))
    parser.add_argument("--delay", type=float, default=0.2, help="Seconds between API requests (default: 0.2)")
    args = parser.parse_args()

    app_id = args.app_id or None
    app_key = args.app_key or None
    print("Fetching TfL Tube lines and station records…", file=sys.stderr)
    line_records = fetch_json("/Line/Mode/tube/Route", app_id, app_key)
    stop_response = fetch_json("/StopPoint/Mode/tube", app_id, app_key)
    if not isinstance(line_records, list) or not isinstance(stop_response, dict):
        raise RuntimeError("Unexpected response from TfL line or station endpoint")

    line_records = sorted(line_records, key=lambda item: item["id"])
    lines = [{"id": item["id"], "name": item["name"], "mode": item.get("modeName", "tube")} for item in line_records]
    raw_stops = stop_response.get("stopPoints", [])
    stop_by_id: dict[str, dict] = {}
    for record in raw_stops:
        if record.get("stopType") == "NaptanMetroStation":
            identifier = station_id(record)
            if identifier:
                stop_by_id[identifier] = record

    routes: list[dict] = []
    stops_by_id: dict[str, dict] = {}
    segment_keys: set[tuple] = set()
    segments: list[dict] = []
    route_call_count = 0

    for line in lines:
        for direction in ("inbound", "outbound"):
            path = (
                f"/Line/{urllib.parse.quote(line['id'], safe='')}/Route/Sequence/{direction}"
                "?serviceTypes=Regular%2CNight"
            )
            time.sleep(max(args.delay, 0))
            response = fetch_json(path, app_id, app_key)
            route_call_count += 1
            if not isinstance(response, dict):
                raise RuntimeError(f"Unexpected route-sequence response for {line['id']} {direction}")
            for route_index, route in enumerate(response.get("orderedLineRoutes", [])):
                ids = [str(value) for value in route.get("naptanIds", []) if value]
                if len(ids) < 2:
                    continue
                route_id = f"{line['id']}:{direction}:{route.get('serviceType', 'Regular').lower()}:{route_index + 1}"
                routes.append({
                    "id": route_id,
                    "lineId": line["id"],
                    "direction": direction,
                    "serviceType": route.get("serviceType", "Regular"),
                    "name": route.get("name", line["name"]),
                    "stationIds": ids,
                })
                for index, stop in enumerate(response.get("stations", [])):
                    identifier = station_id(stop)
                    if identifier:
                        stops_by_id.setdefault(identifier, stop)
                for index, (from_id, to_id) in enumerate(zip(ids, ids[1:])):
                    key = (route_id, index, from_id, to_id)
                    if key in segment_keys:
                        continue
                    segment_keys.add(key)
                    segments.append({
                        "id": f"{route_id}:{index + 1}",
                        "routeId": route_id,
                        "lineId": line["id"],
                        "direction": direction,
                        "serviceType": route.get("serviceType", "Regular"),
                        "fromStationId": from_id,
                        "toStationId": to_id,
                        "order": index + 1,
                        "typicalRunTimeSeconds": None,
                    })

    if not routes:
        raise RuntimeError("TfL returned no ordered route paths; refusing to write an empty snapshot")

    stations: dict[str, dict] = {}
    route_line_ids: dict[str, set[str]] = {}
    for route in routes:
        for identifier in route["stationIds"]:
            route_line_ids.setdefault(identifier, set()).add(route["lineId"])

    print("Fetching TfL detailed station-topology archive…", file=sys.stderr)
    topology_bytes = fetch_bytes(TOPOLOGY_URL)
    topology_digest = hashlib.sha256(topology_bytes).hexdigest()
    try:
        topology_archive = zipfile.ZipFile(io.BytesIO(topology_bytes))
    except zipfile.BadZipFile as error:
        raise RuntimeError("TfL detailed station-topology download was not a valid ZIP archive") from error
    topology_station_rows = read_csv_archive(topology_archive, "Stations.csv")
    topology_station_by_id = {row["UniqueId"]: row for row in topology_station_rows}
    topology_by_network_id = {}
    for identifier in route_line_ids:
        source = stop_by_id.get(identifier) or stops_by_id.get(identifier) or {}
        candidate = identifier if identifier in topology_station_by_id else source.get("hubNaptanCode")
        if candidate in topology_station_by_id:
            topology_by_network_id[identifier] = candidate
    if len(topology_by_network_id) < len(route_line_ids):
        missing = sorted(set(route_line_ids) - set(topology_by_network_id))
        raise RuntimeError(f"TfL topology archive has no station topology for {len(missing)} Tube stations: {missing[:8]}")
    topology_station_ids = set(topology_by_network_id.values())
    topology_stations = [topology_station_by_id[key] for key in sorted(topology_station_ids)]
    topology_feed_info = read_csv_archive(topology_archive, "FeedInfo.csv")

    platforms_all = read_csv_archive(topology_archive, "Platforms.csv")
    platforms = [row for row in platforms_all if row.get("StationUniqueId") in topology_station_ids]
    platform_ids = {row["UniqueId"] for row in platforms}
    platform_services_all = read_csv_archive(topology_archive, "PlatformServices.csv")
    tube_line_ids = {line["id"] for line in lines}
    platform_services = [
        row for row in platform_services_all
        if row.get("PlatformUniqueId") in platform_ids and row.get("Line") in tube_line_ids
    ]
    platform_line_ids: dict[str, set[str]] = {}
    for service in platform_services:
        platform_line_ids.setdefault(service["PlatformUniqueId"], set()).add(service["Line"])

    station_points = [
        row for row in read_csv_archive(topology_archive, "StationPoints.csv")
        if row.get("StationUniqueId") in topology_station_ids
    ]
    point_ids = {row["UniqueId"] for row in station_points}
    outside_records = [
        {"UniqueId": row["OutsideStationUniqueId"], "StationUniqueId": row["UniqueId"]}
        for row in topology_stations
        if row.get("OutsideStationUniqueId")
    ]
    outside_ids = {row["UniqueId"] for row in outside_records}
    topology_node_ids = point_ids | platform_ids | outside_ids
    topology_paths: list[dict] = []
    topology_lifts: list[dict] = []
    for filename, path_type in (("SameLevelPaths.csv", "same-level"), ("RampRoutes.csv", "ramp")):
        for row in read_csv_archive(topology_archive, filename):
            source, target = row.get("From"), row.get("To")
            if source in topology_node_ids and target in topology_node_ids:
                topology_paths.append({"from": source, "to": target, "type": path_type})
    for lift in read_csv_archive(topology_archive, "Lifts.csv"):
        if lift.get("StationUniqueId") not in topology_station_ids:
            continue
        topology_lifts.append({
            "id": lift.get("LiftUniqueId"),
            "topologyStationId": lift.get("StationUniqueId"),
            "name": lift.get("FriendlyName") or lift.get("LiftName") or None,
            "limitedCapacity": lift.get("LimitedCapacityLift", "").lower() == "true",
            "notes": lift.get("LiftNotes") or None,
        })
        levels = [
            list(filter(None, lift.get(key, "").split("|")))
            for key in ("FromAreas", "IntermediateAreas", "IntermediateAreas2", "ToAreas")
        ]
        levels = [level for level in levels if level]
        for left, right in zip(levels, levels[1:]):
            for source in left:
                for target in right:
                    if source in topology_node_ids and target in topology_node_ids:
                        topology_paths.append({"from": source, "to": target, "type": "lift", "liftId": lift.get("LiftUniqueId")})
                        topology_paths.append({"from": target, "to": source, "type": "lift", "liftId": lift.get("LiftUniqueId")})
    topology_adjacency: dict[str, set[str]] = {}
    for path in topology_paths:
        topology_adjacency.setdefault(path["from"], set()).add(path["to"])

    feed_station_by_id = {row["UniqueId"]: row for row in topology_stations}
    platform_step_free: dict[str, str] = {}
    for platform in platforms:
        platform_id = platform["UniqueId"]
        if platform.get("HasStepFreeRouteInformation", "").lower() != "true":
            platform_step_free[platform_id] = "unknown"
            continue
        feed_station = feed_station_by_id.get(platform.get("StationUniqueId"), {})
        outside = feed_station.get("OutsideStationUniqueId")
        pending = [outside] if outside else []
        visited = set(pending)
        while pending:
            current = pending.pop()
            for neighbour in topology_adjacency.get(current, ()):
                if neighbour not in visited:
                    visited.add(neighbour)
                    pending.append(neighbour)
        platform_step_free[platform_id] = "available" if platform_id in visited else "no-recorded-path"

    platform_records = [
        {
            "id": row["UniqueId"],
            "topologyStationId": row["StationUniqueId"],
            "platformNumber": row.get("PlatformNumber") or None,
            "direction": row.get("CardinalDirection") or None,
            "name": row.get("FriendlyName") or None,
            "naptanId": row.get("PlatformNaptanCode") or None,
            "accessibleEntranceName": row.get("AccessibleEntranceName") or None,
            "lineIds": sorted(platform_line_ids.get(row["UniqueId"], set())),
            "hasServiceInterchange": row.get("HasServiceInterchange", "").lower() == "true",
            "hasStepFreeRouteInformation": row.get("HasStepFreeRouteInformation", "").lower() == "true",
            "stepFreeFromStreet": platform_step_free[row["UniqueId"]],
        }
        for row in platforms
    ]
    platform_service_records = [
        {
            "platformId": row["PlatformUniqueId"],
            "stationId": row.get("StopAreaNaptanCode") or None,
            "lineId": row["Line"],
            "directionTowards": row.get("DirectionTowards") or None,
            "minStepMillimetres": row.get("MinStep") or None,
            "maxStepMillimetres": row.get("MaxStep") or None,
            "minGapMillimetres": row.get("MinGap") or None,
            "maxGapMillimetres": row.get("MaxGap") or None,
            "designatedLevelAccessPoint": row.get("DesignatedLevelAccessPoint", "").lower() == "true",
            "manualRampRequired": row.get("LevelAccessByManualRamp", "").lower() == "true",
            "accessibilityNotes": row.get("AdditionalAccessibilityInformation") or None,
            "groupName": row.get("GroupName") or None,
        }
        for row in platform_services
    ]
    point_records = [
        {
            "id": row["UniqueId"],
            "topologyStationId": row["StationUniqueId"],
            "level": float(row["Level"]) if row.get("Level") else None,
            "latitude": float(row["Lat"]) if row.get("Lat") else None,
            "longitude": float(row["Lon"]) if row.get("Lon") else None,
            "name": row.get("FriendlyName") or None,
        }
        for row in station_points
    ]
    point_records.extend({
        "id": row["UniqueId"],
        "topologyStationId": row["StationUniqueId"],
        "level": None,
        "latitude": None,
        "longitude": None,
        "name": "Outside station",
    } for row in outside_records)
    step_free_interchanges = [
        {
            "fromPlatformId": row["FromPlatformUniqueId"],
            "toPlatformId": row["ToPlatformUniqueId"],
            "distanceMetres": float(row["DistanceInMetres"]) if row.get("DistanceInMetres") else None,
        }
        for row in read_csv_archive(topology_archive, "StepFreeIntechangeInfo.csv")
        if row.get("FromPlatformUniqueId") in platform_ids and row.get("ToPlatformUniqueId") in platform_ids
    ]

    for identifier in sorted(route_line_ids):
        source = stop_by_id.get(identifier) or stops_by_id.get(identifier)
        if source is None:
            raise RuntimeError(f"TfL route references station {identifier}, but no station record was returned")
        properties = props_by_key(source)
        name = source.get("commonName") or source.get("name") or identifier
        lines_for_station = sorted(route_line_ids[identifier])
        stations[identifier] = {
            "id": identifier,
            "name": clean_station_name(name),
            "latitude": source.get("lat"),
            "longitude": source.get("lon"),
            "zone": properties.get("Zone"),
            "hubId": source.get("hubNaptanCode"),
            "topologyStationId": topology_by_network_id.get(identifier),
            "lineIds": lines_for_station,
            "accessViaLift": properties.get("AccessViaLift"),
        }

    # Shared station IDs are direct interchanges. TfL also assigns the same hub
    # code to a small number of separately named station complexes (for example,
    # the two Hammersmith stations); preserve those links as distinct nodes.
    hubs: dict[str, list[str]] = {}
    for identifier, station in stations.items():
        if station["hubId"]:
            hubs.setdefault(station["hubId"], []).append(identifier)
    interchange_groups = []
    for identifier, station in sorted(stations.items()):
        if len(station["lineIds"]) > 1:
            interchange_groups.append({
                "id": f"station:{identifier}",
                "stationIds": [identifier],
                "lineIds": station["lineIds"],
                "type": "same-station",
                "transferTimeSeconds": None,
            })
    for hub_id, identifiers in sorted(hubs.items()):
        unique_ids = sorted(set(identifiers))
        if len(unique_ids) > 1:
            interchange_groups.append({
                "id": f"hub:{hub_id}",
                "stationIds": unique_ids,
                "lineIds": sorted({line_id for identifier in unique_ids for line_id in stations[identifier]["lineIds"]}),
                "type": "linked-stations",
                "transferTimeSeconds": None,
            })

    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    version = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
    dataset = {
        "schemaVersion": 1,
        "networkId": "london-underground",
        "version": version,
        "generatedAt": generated_at,
        "source": {
            "name": "Transport for London Unified API",
            "attribution": "Powered by TfL Open Data",
            "licence": "Open Government Licence v3.0, subject to TfL Transport Data Service terms and conditions",
            "licenceUrl": "https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/",
            "termsUrl": "https://tfl.gov.uk/corporate/terms-and-conditions/transport-data-service",
            "dataSources": [
                {"url": f"{API_BASE}/Line/Mode/tube/Route", "recordCount": len(line_records)},
                {"url": f"{API_BASE}/Line/{{lineId}}/Route/Sequence/{{direction}}?serviceTypes=Regular,Night", "recordCount": route_call_count},
                {"url": f"{API_BASE}/StopPoint/Mode/tube", "recordCount": len(raw_stops)},
                {"url": TOPOLOGY_URL, "recordCount": len(topology_station_ids), "feedStartDate": topology_feed_info[0].get("FeedStartDate") if topology_feed_info else None, "archiveSha256": topology_digest},
            ],
        },
        "lines": lines,
        "stations": list(stations.values()),
        "routes": routes,
        "segments": segments,
        "interchanges": interchange_groups,
        "stepFreeTopology": {
            "sourceFormat": "TfL detailed station topology CSV archive",
            "topologyStations": topology_stations,
            "platforms": platform_records,
            "tubePlatformServices": platform_service_records,
            "stationPoints": point_records,
            "paths": topology_paths,
            "lifts": topology_lifts,
            "stepFreePlatformInterchanges": step_free_interchanges,
        },
        "coverage": {
            "serviceTypes": ["Regular", "Night"],
            "stationCount": len(stations),
            "lineCount": len(lines),
            "routeCount": len(routes),
            "segmentCount": len(segments),
            "accessViaLiftField": "TfL AccessViaLift station attribute; detailed platform-level paths are in stepFreeTopology",
            "stepFreeTopologyIncluded": True,
            "stepFreeRoutingReady": False,
            "stepFreeRoutingLimitation": "Static step-free topology is included; live lift outages are not.",
            "interchangeCoverage": "shared station IDs and TfL hub codes; no transfer path or duration supplied",
            "walkingLinksIncluded": False,
            "scheduledRunTimesIncluded": False,
            "liveDisruptionsIncluded": False,
        },
    }

    # Integrity checks needed before publishing a snapshot; these are data validation, not a test suite.
    station_ids = set(stations)
    if len(lines) != 11:
        raise RuntimeError(f"Expected 11 London Underground lines; received {len(lines)}")
    if len(stations) < 250:
        raise RuntimeError(f"Station count unexpectedly low ({len(stations)}); refusing to write snapshot")
    if any(identifier not in station_ids for route in routes for identifier in route["stationIds"]):
        raise RuntimeError("At least one ordered route references a missing station")
    if any(edge["fromStationId"] not in station_ids or edge["toStationId"] not in station_ids for edge in segments):
        raise RuntimeError("At least one segment references a missing station")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    encoded = (json.dumps(dataset, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    temporary.write_bytes(encoded)
    temporary.replace(args.output)
    digest = hashlib.sha256(encoded).hexdigest()
    manifest = {
        "schemaVersion": 1,
        "cityId": "gb-london",
        "networkId": dataset["networkId"],
        "version": version,
        "generatedAt": generated_at,
        "snapshot": f"/datasets/v1/cities/gb-london/networks/{dataset['networkId']}/versions/{version}/network.json",
        "sizeBytes": len(encoded),
        "sha256": digest,
        "coverage": dataset["coverage"],
        "attribution": dataset["source"]["attribution"],
        "licenceUrl": dataset["source"]["licenceUrl"],
        "termsUrl": dataset["source"]["termsUrl"],
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest_tmp = args.manifest.with_suffix(args.manifest.suffix + ".tmp")
    manifest_tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    manifest_tmp.replace(args.manifest)
    print(
        f"Wrote {args.output}: {len(lines)} lines, {len(stations)} stations, "
        f"{len(routes)} directional service paths, {len(segments)} segments; "
        f"{len(encoded):,} bytes; sha256={digest}; manifest={args.manifest}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, KeyError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
