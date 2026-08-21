#!/usr/bin/env python3
"""Build the bounded web-planner sailing POI catalogue from Overpass exports."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


CATEGORY_LABELS = {
    "harbour": "Harbour",
    "marina": "Marina",
    "anchorage": "Anchorage",
    "mooring": "Mooring area",
    "slipway": "Slipway",
    "service": "Small-craft service",
    "structure": "Marine structure",
}

HARBOUR_FACILITIES = {
    "harbour:visitor_berth": "visitor berths",
    "harbour:visitors_mooring": "visitor moorings",
    "harbour:water_tap": "drinking water",
    "harbour:electricity": "shore power",
    "harbour:fuel_station": "fuel",
    "harbour:pump-out": "pump-out",
    "harbour:showers": "showers",
    "harbour:toilets": "toilets",
    "harbour:boatyard": "boatyard",
    "harbour:boat_hoist": "boat hoist",
    "harbour:sailmaker": "sailmaker",
    "harbour:mechanics_workshop": "repairs",
    "harbour:nautical_club": "sailing club",
}


def classify(tags: dict[str, str]) -> tuple[str, str | None]:
    seamark_type = tags.get("seamark:type")
    anchorage_category = tags.get("seamark:anchorage:category", "")
    if tags.get("leisure") == "marina":
        return "marina", tags.get("seamark:harbour:category")
    if tags.get("harbour") == "yes" or tags.get("industrial") == "port":
        return "harbour", tags.get("seamark:harbour:category") or "port"
    if seamark_type == "anchorage":
        if "mooring" in anchorage_category:
            return "mooring", anchorage_category.replace("_", " ")
        return "anchorage", anchorage_category.replace("_", " ") or None
    if seamark_type in {"mooring", "mooring_buoy"} or tags.get("mooring"):
        return "mooring", (
            tags.get("seamark:mooring:category") or tags.get("mooring") or "mooring"
        ).replace("_", " ")
    if seamark_type == "harbour":
        return "harbour", tags.get("seamark:harbour:category")
    if tags.get("leisure") == "slipway":
        return "slipway", tags.get("access")
    if seamark_type in {"bridge", "gate", "lock_basin"}:
        return "structure", seamark_type.replace("_", " ")
    facility = tags.get("seamark:small_craft_facility:category")
    if facility:
        return "service", facility.replace("_", " ").replace(";", ", ")
    if seamark_type == "rescue_station":
        return "service", "rescue station"
    if tags.get("waterway") == "boatyard":
        return "service", "boatyard"
    if tags.get("craft") == "sailmaker":
        return "service", "sailmaker"
    if tags.get("shop") == "boat":
        return "service", "boat supplies"
    return "service", None


def facility_summary(tags: dict[str, str], fallback: str | None) -> str | None:
    facilities = [
        label
        for key, label in HARBOUR_FACILITIES.items()
        if tags.get(key, "").casefold() not in {"", "no", "none", "unknown"}
    ]
    if facilities:
        return ", ".join(facilities)
    return fallback


def osm_feature(element: dict[str, Any], source_updated: str) -> dict[str, Any] | None:
    tags = element.get("tags") or {}
    coordinate = element if element.get("type") == "node" else element.get("center")
    if not coordinate:
        return None
    latitude = coordinate.get("lat")
    longitude = coordinate.get("lon")
    if not isinstance(latitude, (int, float)) or not isinstance(
        longitude, (int, float)
    ):
        return None
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
        return None

    category, facility = classify(tags)
    facility = facility_summary(tags, facility)
    element_type = str(element["type"])
    element_id = int(element["id"])
    name = (
        tags.get("name")
        or tags.get("seamark:name")
        or tags.get("operator")
        or CATEGORY_LABELS[category]
    )
    properties = {
        "name": " ".join(str(name).split())[:160],
        "category": category,
        "facility": facility,
        "operator": tags.get("operator"),
        "sourceName": "OpenStreetMap",
        "sourceFeatureId": f"osm:{element_type}/{element_id}",
        "sourceUrl": f"https://www.openstreetmap.org/{element_type}/{element_id}",
        "sourceUpdated": source_updated,
        "licence": "ODbL 1.0",
        "warning": "Community-maintained place data. Verify access, facilities and local restrictions.",
    }
    return {
        "type": "Feature",
        "id": properties["sourceFeatureId"],
        "geometry": {"type": "Point", "coordinates": [longitude, latitude]},
        "properties": {key: value for key, value in properties.items() if value},
    }


def tide_features(path: Path) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    source = payload["source"]
    return [
        {
            "type": "Feature",
            "id": f"tide:{station['id']}",
            "geometry": {
                "type": "Point",
                "coordinates": [station["longitude"], station["latitude"]],
            },
            "properties": {
                "name": station["name"],
                "category": "tide_station",
                "facility": f"Astronomical tide prediction · {station['chartDatum']}",
                "sourceName": source["name"],
                "sourceFeatureId": station["id"],
                "sourceUrl": source["url"],
                "sourceUpdated": payload["generatedFrom"]["databaseCommit"][:12],
                "licence": source["licence"],
                "warning": source["warning"],
            },
        }
        for station in payload["stations"]
    ]


def build_catalogue(inputs: list[Path], tide_data: Path) -> dict[str, Any]:
    features: list[dict[str, Any]] = []
    source_timestamps: list[str] = []
    seen: set[str] = set()
    for path in inputs:
        payload = json.loads(path.read_text(encoding="utf-8"))
        source_updated = payload.get("osm3s", {}).get("timestamp_osm_base", "unknown")
        source_timestamps.append(source_updated)
        for element in payload.get("elements", []):
            feature = osm_feature(element, source_updated)
            if feature is None or feature["id"] in seen:
                continue
            seen.add(feature["id"])
            features.append(feature)
    features.extend(tide_features(tide_data))
    features.sort(
        key=lambda feature: (
            feature["properties"]["category"],
            feature["properties"]["name"].casefold(),
            feature["id"],
        )
    )
    return {
        "type": "FeatureCollection",
        "metadata": {
            "schemaVersion": 1,
            "coverage": "Solent starter area: 50.55–51.05 N, 1.95–0.75 W",
            "source": "OpenStreetMap Overpass extracts plus Tide and Seek bundled tide stations",
            "sourceUpdated": max(source_timestamps),
            "attribution": "© OpenStreetMap contributors, ODbL; TICON-4 via Neaps, CC BY 4.0",
            "warning": "Planning context only. Not an official chart or pilotage publication.",
        },
        "features": features,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--tide-data", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    catalogue = build_catalogue(args.inputs, args.tide_data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(catalogue, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(catalogue['features'])} sailing places to {args.output}")


if __name__ == "__main__":
    main()
