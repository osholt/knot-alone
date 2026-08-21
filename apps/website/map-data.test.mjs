import test from "node:test";
import assert from "node:assert/strict";

import {
  boundsContain,
  createContourRequest,
  createGebcoContourRequest,
  deriveShallowContours,
  parseEmodnetGrid,
  parseGebcoGrid,
} from "./emodnet-contours.mjs";
import { windFieldGeoJson, windGrid, windRequestUrl } from "./wind-field.mjs";
import {
  currentEffect,
  currentFieldGeoJson,
  currentGridDimensions,
  currentSampleTimings,
  depthAdjustmentFor,
  estimatePassageWithCurrents,
  marineGrid,
  marineRequestUrl,
  routeCurrentGeoJson,
  routeSamplePlan,
  sampleMarineAt,
} from "./tide-current.mjs";

test("builds a bounded EMODnet request across England", () => {
  const request = createContourRequest(
    { west: -5.8, south: 49.8, east: 1.8, north: 55.9 },
    8,
  );
  assert.ok(request.url.includes("coverageId=emodnet__mean"));
  assert.ok(request.url.includes("scaleSize=i%28"));
  assert.ok(request.gridWidth <= 320);
  assert.ok(request.gridHeight <= 240);
  assert.equal(createContourRequest({ west: 120, south: -40, east: 130, north: -30 }, 9), null);
  assert.ok(boundsContain(request.bounds, { west: -5, south: 50, east: 1, north: 55 }));
});

test("parses negative seabed elevations into shallow contours", () => {
  const text = `Grid range: GridEnvelope2D[0..3, 0..3]
Grid to world: PARAM_MT["Affine",
  PARAMETER["elt_0_0", 0.01],
  PARAMETER["elt_0_2", -1.5],
  PARAMETER["elt_1_1", -0.01],
  PARAMETER["elt_1_2", 51.0]]
Contents:
Band 0:
-1 -1 -1 -1
-1 -10 -10 -1
-1 -10 -10 -1
-1 -1 -1 -1`;
  const parsed = parseEmodnetGrid(text);
  const contours = deriveShallowContours(parsed, [5]);
  assert.equal(parsed.rows.length, 4);
  assert.equal(contours.features.length, 1);
  assert.equal(contours.features[0].properties.label, "5 m");
  assert.ok(contours.features[0].geometry.coordinates.every(([longitude]) => longitude < -1.47));
});

test("omits contour interpolation through cells containing positive land", () => {
  const text = `Grid range: GridEnvelope2D[0..3, 0..3]
Grid to world: PARAM_MT["Affine",
  PARAMETER["elt_0_0", 0.01],
  PARAMETER["elt_0_2", -5.05],
  PARAMETER["elt_1_1", -0.01],
  PARAMETER["elt_1_2", 50.17]]
Contents:
Band 0:
3 3 3 3
3 -10 -10 3
3 -10 -10 3
3 3 3 3`;
  const contours = deriveShallowContours(parseEmodnetGrid(text), [5]);
  assert.equal(contours.features.length, 0);
});

test("builds and parses a bounded GEBCO global fallback request", () => {
  const request = createGebcoContourRequest(
    { west: 151.0, south: -34.2, east: 151.5, north: -33.7 },
    10,
  );
  assert.match(request.url, /GEBCO_2026\.nc\.ascii\?elevation\[/);
  assert.ok(request.gridWidth <= 320);
  assert.ok(request.gridHeight <= 240);
  assert.equal(
    createGebcoContourRequest({ west: 179, south: -20, east: 181, north: -19 }, 9),
    null,
  );

  const text = `elevation.elevation[4][4]
[0], -1, -1, -1, -1
[1], -1, -10, -10, -1
[2], -1, -10, -10, -1
[3], -1, -1, -1, -1

elevation.lat[4]
-34.0, -33.99, -33.98, -33.97

elevation.lon[4]
151.0, 151.01, 151.02, 151.03`;
  const parsed = parseGebcoGrid(text);
  const contours = deriveShallowContours(parsed, [5], {
    featurePrefix: "gebco-live",
    sourceName: "GEBCO 2026 Grid",
  });
  assert.equal(parsed.rows.length, 4);
  assert.equal(contours.features.length, 1);
  assert.equal(contours.features[0].properties.sourceName, "GEBCO 2026 Grid");
  assert.match(contours.features[0].id, /^gebco-live-/);
});

test("builds a map-wide wind field with downwind arrows and labels", () => {
  const bounds = { west: -2, south: 50, east: 0, north: 52 };
  const points = windGrid(bounds, 2, 1);
  assert.equal(points.length, 2);
  assert.match(windRequestUrl(points), /wind_speed_10m/);
  const response = points.map(() => ({
    current: {
      time: "2026-08-21T14:15",
      wind_speed_10m: 12.4,
      wind_direction_10m: 0,
      wind_gusts_10m: 19.2,
    },
  }));
  const field = windFieldGeoJson(points, response, bounds, 2, 1);
  assert.equal(field.geojson.features.length, 4);
  assert.equal(field.geojson.features[0].geometry.type, "MultiLineString");
  assert.equal(field.geojson.features[1].properties.speedLabel, "12 kn");
  const [start, end] = field.geojson.features[0].geometry.coordinates[0];
  assert.ok(end[1] < start[1], "a north wind should point downwind to the south");
});

test("interpolates a map-wide current field at the selected passage start", () => {
  const bounds = { west: -1.6, south: 50.7, east: -1.0, north: 50.9 };
  const points = marineGrid(bounds, 2, 1);
  const start = new Date("2026-08-21T14:30:00Z");
  assert.equal(points.length, 2);
  assert.match(
    marineRequestUrl(points, start, new Date("2026-08-21T16:00:00Z")),
    /ocean_current_velocity/,
  );
  const response = points.map(() => ({
    hourly: {
      time: ["2026-08-21T14:00", "2026-08-21T15:00"],
      ocean_current_velocity: [1, 1],
      ocean_current_direction: [90, 180],
      sea_level_height_msl: [-0.2, 0.2],
    },
  }));
  const sample = sampleMarineAt(response[0], start);
  assert.ok(sample.speedKnots > 0.7 && sample.speedKnots < 0.71);
  assert.ok(sample.directionTowards > 134 && sample.directionTowards < 136);
  assert.ok(Math.abs(sample.seaLevelMsl) < 0.001);
  const field = currentFieldGeoJson(points, response, bounds, start, 2, 1);
  assert.equal(field.geojson.features.length, 4);
  assert.equal(field.geojson.features[0].properties.kind, "current-arrow");
});

test("adapts current grid density to the map zoom", () => {
  const wide = currentGridDimensions(1_000, 700, 4);
  const close = currentGridDimensions(1_000, 700, 14);
  assert.deepEqual(wide, { columns: 5, rows: 3 });
  assert.deepEqual(close, { columns: 10, rows: 7 });
});

test("blends current time into expected route time by distance", () => {
  const estimate = {
    startTime: "2026-08-21T12:00:00.000Z",
    legs: [{
      from: { longitude: -1.5, latitude: 50.75 },
      to: { longitude: -1.3, latitude: 50.75 },
      startTime: "2026-08-21T12:00:00.000Z",
      arrivalTime: "2026-08-21T14:00:00.000Z",
    }],
  };
  const timings = currentSampleTimings(
    [
      { longitude: -1.4, latitude: 50.75 },
      { longitude: -1.4, latitude: 50.83 },
      { longitude: -1.4, latitude: 51.1 },
    ],
    new Date("2026-08-21T10:00:00Z"),
    estimate,
  );
  assert.equal(timings[0].forecastWeight, 1);
  assert.equal(timings[0].sampleTime.toISOString(), "2026-08-21T13:00:00.000Z");
  assert.ok(timings[1].forecastWeight > 0 && timings[1].forecastWeight < 1);
  assert.equal(timings[2].forecastWeight, 0);
  assert.equal(timings[2].sampleTime.toISOString(), "2026-08-21T10:00:00.000Z");
});

test("uses compatible datums for tide-adjusted depths", () => {
  const adjustment = depthAdjustmentFor({
    provider: "emodnet",
    point: { longitude: -1.5, latitude: 50.74 },
    seaLevelMsl: 0.25,
  });
  assert.equal(adjustment.chartDatum, "LAT");
  assert.equal(adjustment.stationName, "Lymington");
  assert.ok(adjustment.heightM > 2.2 && adjustment.heightM < 2.21);
  assert.equal(
    depthAdjustmentFor({
      provider: "emodnet",
      point: { longitude: 10, latitude: 60 },
      seaLevelMsl: 0.25,
    }),
    null,
  );
});

test("adjusts each leg estimate using the current expected at its midpoint", () => {
  const effect = currentEffect(5, 90, 1, 90);
  assert.equal(effect.effectiveSpeedKnots, 6);
  const summary = {
    legs: [{
      index: 1,
      from: { longitude: -1.5, latitude: 50.75 },
      to: { longitude: -1.3, latitude: 50.75 },
      distanceMetres: 18_520,
      bearingDegrees: 90,
    }],
  };
  const samplePlan = routeSamplePlan(summary);
  const response = samplePlan.map(() => ({
    hourly: {
      time: ["2026-08-21T12:00", "2026-08-21T18:00"],
      ocean_current_velocity: [1, 1],
      ocean_current_direction: [90, 90],
      sea_level_height_msl: [0, 0],
    },
  }));
  const estimate = estimatePassageWithCurrents(
    summary,
    response,
    new Date("2026-08-21T12:00:00Z"),
    5,
    samplePlan,
  );
  assert.equal(estimate.complete, true);
  assert.ok(estimate.durationSeconds > 5_990 && estimate.durationSeconds < 6_010);
  assert.equal(estimate.legs[0].effectiveSpeedKnots, 6);
  assert.equal(estimate.legs[0].samples.length, 4);
});

test("plots repeated course-to-steer arrows and an uncorrected drift track", () => {
  const summary = {
    legs: [{
      index: 1,
      from: { longitude: -1.5, latitude: 50.75 },
      to: { longitude: -1.3, latitude: 50.75 },
      distanceMetres: 18_520,
      bearingDegrees: 90,
    }],
  };
  const samplePlan = routeSamplePlan(summary);
  const responses = samplePlan.map(() => ({
    hourly: {
      time: ["2026-08-21T12:00", "2026-08-21T18:00"],
      ocean_current_velocity: [1, 1],
      ocean_current_direction: [0, 0],
      sea_level_height_msl: [0, 0],
    },
  }));
  const estimate = estimatePassageWithCurrents(
    summary,
    responses,
    new Date("2026-08-21T12:00:00Z"),
    5,
    samplePlan,
  );
  assert.ok(estimate.legs[0].samples.every((sample) => sample.headingDegrees > 101));
  assert.ok(estimate.driftCoordinates.at(-1)[1] > summary.legs[0].to.latitude);
  const geojson = routeCurrentGeoJson(estimate);
  assert.equal(
    geojson.features.filter((feature) => feature.properties.kind === "course-to-steer-arrow").length,
    samplePlan.length,
  );
  assert.equal(
    geojson.features.filter((feature) => feature.properties.kind === "drift-line").length,
    1,
  );
});
