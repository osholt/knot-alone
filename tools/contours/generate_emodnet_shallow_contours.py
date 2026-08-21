#!/usr/bin/env python3
"""Derive bounded shallow-water contours from the free EMODnet mean-depth grid."""

from __future__ import annotations

import argparse
import json
import math
import re
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path


WCS_URL = "https://ows.emodnet-bathymetry.eu/wcs"
DEFAULT_BBOX = (-1.7, 50.5, -0.9, 51.0)
DEFAULT_LEVELS = (2.0, 5.0, 10.0, 20.0, 30.0)
GRID_VALUE = re.compile(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?")


def fetch_grid(bbox: tuple[float, float, float, float]) -> str:
    west, south, east, north = bbox
    query = urllib.parse.urlencode(
        {
            "service": "WCS",
            "version": "2.0.1",
            "request": "GetCoverage",
            "coverageId": "emodnet__mean",
            "subset": [f"Long({west},{east})", f"Lat({south},{north})"],
            "format": "text/plain",
        },
        doseq=True,
    )
    request = urllib.request.Request(
        f"{WCS_URL}?{query}",
        headers={"User-Agent": "Tide-and-Seek contour generator"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read().decode("utf-8")


def parse_grid(text: str) -> tuple[list[list[float]], tuple[float, float, float, float]]:
    range_match = re.search(r"Grid range: GridEnvelope2D\[0\.\.(\d+), 0\.\.(\d+)\]", text)
    transform_values = {
        key: float(value)
        for key, value in re.findall(
            r'PARAMETER\["elt_(0_0|0_2|1_1|1_2)",\s*([-+0-9.eE]+)\]', text
        )
    }
    contents = text.partition("Band 0:")[2]
    if not range_match or len(transform_values) != 4 or not contents:
        raise ValueError("Unrecognised EMODnet text-grid response")

    width, height = int(range_match.group(1)) + 1, int(range_match.group(2)) + 1
    values = [float(value) for value in GRID_VALUE.findall(contents)]
    if len(values) != width * height:
        raise ValueError(f"Expected {width * height} grid values, received {len(values)}")
    rows = [values[offset : offset + width] for offset in range(0, len(values), width)]
    transform = (
        transform_values["0_0"],
        transform_values["0_2"],
        transform_values["1_1"],
        transform_values["1_2"],
    )
    return rows, transform


def interpolate(first: float, second: float, level: float) -> float:
    if first == second:
        return 0.5
    return max(0.0, min(1.0, (level - first) / (second - first)))


def edge_point(
    row: int,
    column: int,
    edge: int,
    corners: tuple[float, float, float, float],
    level: float,
) -> tuple[float, float]:
    top_left, top_right, bottom_right, bottom_left = corners
    if edge == 0:
        return row, column + interpolate(top_left, top_right, level)
    if edge == 1:
        return row + interpolate(top_right, bottom_right, level), column + 1
    if edge == 2:
        return row + 1, column + interpolate(bottom_left, bottom_right, level)
    return row + interpolate(top_left, bottom_left, level), column


def contour_segments(
    grid: list[list[float]], level: float
) -> list[tuple[tuple[float, float], tuple[float, float]]]:
    cases = {
        1: ((3, 0),),
        2: ((0, 1),),
        3: ((3, 1),),
        4: ((1, 2),),
        6: ((0, 2),),
        7: ((3, 2),),
        8: ((2, 3),),
        9: ((0, 2),),
        11: ((1, 2),),
        12: ((1, 3),),
        13: ((0, 1),),
        14: ((3, 0),),
    }
    segments = []
    for row in range(len(grid) - 1):
        for column in range(len(grid[0]) - 1):
            corners = (
                grid[row][column],
                grid[row][column + 1],
                grid[row + 1][column + 1],
                grid[row + 1][column],
            )
            case = sum(1 << index for index, value in enumerate(corners) if value >= level)
            if case in (0, 15):
                continue
            if case == 5:
                pairs = ((0, 1), (2, 3)) if sum(corners) / 4 >= level else ((3, 0), (1, 2))
            elif case == 10:
                pairs = ((3, 0), (1, 2)) if sum(corners) / 4 >= level else ((0, 1), (2, 3))
            else:
                pairs = cases[case]
            segments.extend(
                (edge_point(row, column, first, corners, level), edge_point(row, column, second, corners, level))
                for first, second in pairs
            )
    return segments


def point_key(point: tuple[float, float]) -> tuple[int, int]:
    return round(point[0] * 1_000_000), round(point[1] * 1_000_000)


def stitch_segments(
    segments: list[tuple[tuple[float, float], tuple[float, float]]]
) -> list[list[tuple[float, float]]]:
    points: dict[tuple[int, int], tuple[float, float]] = {}
    adjacency: dict[tuple[int, int], list[tuple[int, tuple[int, int]]]] = defaultdict(list)
    for index, (first, second) in enumerate(segments):
        first_key, second_key = point_key(first), point_key(second)
        points[first_key], points[second_key] = first, second
        adjacency[first_key].append((index, second_key))
        adjacency[second_key].append((index, first_key))

    used: set[int] = set()
    lines: list[list[tuple[float, float]]] = []

    def follow(start: tuple[int, int]) -> list[tuple[float, float]]:
        line = [points[start]]
        current = start
        while True:
            next_edges = [edge for edge in adjacency[current] if edge[0] not in used]
            if not next_edges:
                return line
            edge_index, neighbour = next_edges[0]
            used.add(edge_index)
            current = neighbour
            line.append(points[current])
            if current == start:
                return line

    for key, edges in adjacency.items():
        if len(edges) != 2:
            while any(index not in used for index, _ in edges):
                lines.append(follow(key))
    for index, (first, _) in enumerate(segments):
        if index not in used:
            lines.append(follow(point_key(first)))
    return lines


def perpendicular_distance(
    point: tuple[float, float], start: tuple[float, float], end: tuple[float, float]
) -> float:
    if start == end:
        return math.dist(point, start)
    numerator = abs(
        (end[1] - start[1]) * point[0]
        - (end[0] - start[0]) * point[1]
        + end[0] * start[1]
        - end[1] * start[0]
    )
    return numerator / math.dist(start, end)


def simplify(line: list[tuple[float, float]], tolerance: float) -> list[tuple[float, float]]:
    if len(line) <= 2:
        return line
    maximum, split = 0.0, 0
    for index in range(1, len(line) - 1):
        distance = perpendicular_distance(line[index], line[0], line[-1])
        if distance > maximum:
            maximum, split = distance, index
    if maximum <= tolerance:
        return [line[0], line[-1]]
    return simplify(line[: split + 1], tolerance)[:-1] + simplify(line[split:], tolerance)


def build_geojson(
    grid: list[list[float]],
    transform: tuple[float, float, float, float],
    levels: tuple[float, ...] = DEFAULT_LEVELS,
) -> dict[str, object]:
    longitude_step, longitude_origin, latitude_step, latitude_origin = transform
    # The WCS grid uses elevation: land is positive and seabed is negative.
    # Convert it to positive water depth before applying the requested isobaths.
    depth_grid = [[-value for value in row] for row in grid]
    features = []
    for level in levels:
        for index, line in enumerate(
            stitch_segments(contour_segments(depth_grid, level))
        ):
            if len(line) < 3:
                continue
            coordinates = [
                [
                    round(longitude_origin + column * longitude_step, 6),
                    round(latitude_origin + row * latitude_step, 6),
                ]
                for row, column in line
            ]
            coordinates = simplify(coordinates, 0.00012)
            if len(coordinates) < 2 or sum(
                math.dist(first, second) for first, second in zip(coordinates, coordinates[1:])
            ) < 0.0015:
                continue
            features.append(
                {
                    "type": "Feature",
                    "id": f"emodnet-solent-{int(level)}m-{index}",
                    "properties": {
                        "depthM": level,
                        "label": f"{int(level)} m",
                        "derived": True,
                        "sourceName": "EMODnet Bathymetry DTM 2024",
                        "sourceResolution": "1/16 arc-minute (about 115 m)",
                        "licence": "CC BY 4.0",
                        "warning": "Model-derived contour; not a charted sounding or safe clearance.",
                    },
                    "geometry": {"type": "LineString", "coordinates": coordinates},
                }
            )
    return {
        "type": "FeatureCollection",
        "metadata": {
            "schemaVersion": 1,
            "coverage": "Solent starter area: 50.5–51.0 N, 1.7–0.9 W",
            "levelsMetres": list(levels),
            "source": "EMODnet Bathymetry DTM 2024 mean-depth WCS",
            "sourceUrl": "https://ows.emodnet-bathymetry.eu/",
            "sourceResolution": "1/16 arc-minute (about 115 m)",
            "licence": "CC BY 4.0",
            "warning": "Interpolated model context only. Not surveyed marina depth, a charted sounding, safe clearance or a substitute for current official charts.",
        },
        "features": features,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, help="Previously downloaded EMODnet text grid")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bbox", nargs=4, type=float, default=DEFAULT_BBOX)
    args = parser.parse_args()
    text = args.input.read_text(encoding="utf-8") if args.input else fetch_grid(tuple(args.bbox))
    grid, transform = parse_grid(text)
    geojson = build_geojson(grid, transform)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(geojson, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(geojson['features'])} contour lines to {args.output}")


if __name__ == "__main__":
    main()
