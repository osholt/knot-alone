import test from "node:test";
import assert from "node:assert/strict";

import {
  boundsContain,
  clipContoursToWater,
  contourSampleSupportsZoom,
  createContourRequest,
  createGebcoContourRequest,
  createShadingContourRequest,
  deriveShallowContours,
  geometryContainsCoordinate,
  parseEmodnetColourScale,
  parseEmodnetGrid,
  parseEmodnetShadingGrid,
  parseGebcoGrid,
} from "./emodnet-contours.mjs";
import { sampleWindAt, windFieldGeoJson, windGrid, windRequestUrl } from "./wind-field.mjs";
import { buildShadingContours } from "./contour-worker.mjs";
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
  tideEventsFromResponse,
  tideLevelAt,
  tideRequestUrl,
  tideSeriesFromResponse,
} from "./tide-current.mjs";
import { sunChartRows, sunRequestUrl } from "./sun-times.mjs";
import { clearForecastCache, fetchForecastJson } from "./forecast-cache.mjs";

test("builds a bounded EMODnet request across England", () => {
  const request = createContourRequest(
    { west: -5.8, south: 49.8, east: 1.8, north: 55.9 },
    8,
  );
  assert.ok(request.url.includes("coverageId=emodnet__mean"));
  assert.ok(request.url.includes("scaleSize=i%28"));
  assert.ok(request.gridWidth > 320);
  assert.ok(request.gridWidth <= 512);
  assert.ok(request.gridHeight <= 384);
  assert.equal(createContourRequest({ west: 120, south: -40, east: 130, north: -30 }, 9), null);
  assert.ok(boundsContain(request.bounds, { west: -5, south: 50, east: 1, north: 55 }));
});

test("builds a screen-resolution request for the EMODnet depth shading colours", () => {
  const request = createShadingContourRequest(
    { west: -5.2, south: 50.05, east: -4.95, north: 50.25 },
    12,
    { width: 900, height: 700 },
  );
  assert.match(request.url, /request=GetMap/i);
  assert.match(request.url, /layers=emodnet%3Amean/i);
  assert.match(request.url, /styles=multicolour/i);
  assert.match(request.legendUrl, /GetLegendGraphic/i);
  assert.equal(request.gridWidth, 896);
  assert.equal(request.gridHeight, 672);
  assert.ok(boundsContain(request.bounds, { west: -5.2, south: 50.05, east: -4.95, north: 50.25 }));
});

test("refreshes a cached colour trace as the map zooms in", () => {
  assert.equal(contourSampleSupportsZoom(10, 10.7), true);
  assert.equal(contourSampleSupportsZoom(10, 10.8), false);
  assert.equal(contourSampleSupportsZoom(10, 9), true);
  assert.equal(contourSampleSupportsZoom(null, 10), false);
});

test("recovers shallow depths from the official shading colour ramp", () => {
  const colourScale = parseEmodnetColourScale({
    Legend: [{
      rules: [{
        symbolizers: [{
          Raster: {
            colormap: {
              entries: [
                { quantity: "-50", color: "#FFFF0D" },
                { quantity: "-10", color: "#F90018" },
                { quantity: "0", color: "#FF666A" },
              ],
            },
          },
        }],
      }],
    }],
  });
  const colours = {
    land: [255, 102, 106, 255],
    fiveMetres: [252, 51, 65, 255],
    tenMetres: [249, 0, 24, 255],
  };
  const pixels = new Uint8ClampedArray([
    ...colours.land, ...colours.land, ...colours.land, ...colours.land,
    ...colours.land, ...colours.tenMetres, ...colours.tenMetres, ...colours.land,
    ...colours.land, ...colours.tenMetres, ...colours.tenMetres, ...colours.land,
    ...colours.land, ...colours.land, ...colours.land, ...colours.land,
  ]);
  const parsed = parseEmodnetShadingGrid(
    { width: 4, height: 4, data: pixels },
    colourScale,
    { west: -5.2, south: 50.05, east: -4.95, north: 50.25 },
  );
  assert.ok(Math.abs(parsed.rows[0][0]) < 0.01);
  assert.ok(Math.abs(parsed.rows[1][1] + 10) < 0.01);

  const fiveMetrePixel = new Uint8ClampedArray([
    ...colours.fiveMetres, ...colours.fiveMetres,
    ...colours.fiveMetres, ...colours.fiveMetres,
  ]);
  const fiveMetreGrid = parseEmodnetShadingGrid(
    { width: 2, height: 2, data: fiveMetrePixel },
    colourScale,
    { west: 0, south: 0, east: 1, north: 1 },
  );
  assert.ok(Math.abs(fiveMetreGrid.rows[0][0] + 5) < 0.2);

  const contours = deriveShallowContours(parsed, [5], {
    sourceName: "EMODnet multicolour depth shading",
  });
  const simplified = deriveShallowContours(parsed, [5], {
    simplifyTolerance: 0.04,
    sourceName: "EMODnet multicolour depth shading",
  });
  assert.equal(contours.features.length, 1);
  assert.equal(contours.features[0].properties.label, "5 m");
  assert.ok(
    simplified.features[0].geometry.coordinates.length <
      contours.features[0].geometry.coordinates.length,
  );

  const workerContours = buildShadingContours({
    bounds: { west: -5.2, south: 50.05, east: -4.95, north: 50.25 },
    colourScale,
    height: 4,
    options: { sourceName: "EMODnet multicolour depth shading" },
    pixels: pixels.buffer.slice(0),
    width: 4,
  });
  const workerFiveMetreContours = workerContours.features.filter(
    (feature) => feature.properties.depthM === 5,
  );
  assert.equal(workerFiveMetreContours.length, 1);
  assert.ok(
    workerFiveMetreContours[0].geometry.coordinates.length <
      contours.features[0].geometry.coordinates.length,
  );
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

test("normalises scaled EMODnet grids whose row numbering does not begin at zero", () => {
  const text = `Grid range: GridEnvelope2D[0..1, 1..2]
Grid to world: PARAM_MT["Affine",
  PARAMETER["elt_0_0", 0.02],
  PARAMETER["elt_0_2", -5.1],
  PARAMETER["elt_1_1", -0.02],
  PARAMETER["elt_1_2", 50.2]]
Contents:
Band 0:
-1 -2
-3 -4`;
  const parsed = parseEmodnetGrid(text);
  assert.deepEqual(parsed.rows, [[-1, -2], [-3, -4]]);
  assert.equal(parsed.transform.longitudeOrigin, -5.1);
  assert.equal(parsed.transform.latitudeOrigin, 50.18);
});

test("keeps coastal contour cells connected until the display water mask is applied", () => {
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
  assert.equal(contours.features.length, 1);
  assert.equal(contours.features[0].geometry.coordinates.length, 9);
  const clipped = clipContoursToWater(
    contours,
    () => false,
    { west: -5.1, south: 50.1, east: -5, north: 50.2 },
  );
  assert.equal(clipped.features.length, 0);
});

test("clips only the on-land pieces of a connected contour", () => {
  const contours = {
    type: "FeatureCollection",
    features: [{
      type: "Feature",
      id: "5m",
      properties: { depthM: 5 },
      geometry: {
        type: "LineString",
        coordinates: [[0, 0], [1, 0], [2, 0], [3, 0], [4, 0]],
      },
    }],
  };
  const clipped = clipContoursToWater(
    contours,
    ([longitude]) => longitude < 1.5 || longitude > 2.5,
    { west: 0, south: -1, east: 4, north: 1 },
  );
  assert.deepEqual(
    clipped.features.map((feature) => feature.geometry.coordinates),
    [[[0, 0], [1, 0]], [[3, 0], [4, 0]]],
  );
});

test("recognises rendered water polygons while respecting islands", () => {
  const water = {
    type: "Polygon",
    coordinates: [
      [[0, 0], [5, 0], [5, 5], [0, 5], [0, 0]],
      [[2, 2], [3, 2], [3, 3], [2, 3], [2, 2]],
    ],
  };
  assert.equal(geometryContainsCoordinate(water, [1, 1]), true);
  assert.equal(geometryContainsCoordinate(water, [2.5, 2.5]), false);
  assert.equal(geometryContainsCoordinate(water, [6, 1]), false);
});

test("builds and parses a bounded GEBCO global fallback request", () => {
  const request = createGebcoContourRequest(
    { west: 151.0, south: -34.2, east: 151.5, north: -33.7 },
    10,
  );
  assert.match(request.url, /GEBCO_2026\.nc\.ascii\?elevation\[/);
  assert.ok(request.gridWidth <= 512);
  assert.ok(request.gridHeight <= 384);
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
  const at = new Date("2026-08-21T14:30:00Z");
  assert.match(windRequestUrl(points, at, at), /wind_speed_10m/);
  const response = points.map(() => ({
    hourly: {
      time: ["2026-08-21T14:00", "2026-08-21T15:00"],
      wind_speed_10m: [12.4, 12.4],
      wind_direction_10m: [0, 0],
      wind_gusts_10m: [19.2, 19.2],
    },
  }));
  assert.equal(sampleWindAt(response[0], at).directionFrom, 0);
  const field = windFieldGeoJson(points, response, bounds, at, 2, 1);
  assert.equal(field.geojson.features.length, 4);
  assert.equal(field.geojson.features[0].geometry.type, "MultiLineString");
  assert.equal(field.geojson.features[1].properties.speedLabel, "12 kn · now");
  const [start, end] = field.geojson.features[0].geometry.coordinates[0];
  assert.ok(end[1] < start[1], "a north wind should point downwind to the south");
});

test("shrinks map arrows as the geographic viewport narrows", () => {
  const at = new Date("2026-08-21T14:30:00Z");
  const response = {
    hourly: {
      time: ["2026-08-21T14:00", "2026-08-21T15:00"],
      wind_speed_10m: [12, 12],
      wind_direction_10m: [90, 90],
      wind_gusts_10m: [18, 18],
    },
  };
  const wideBounds = { west: -2, south: 50, east: 0, north: 52 };
  const closeBounds = { west: -1.41, south: 50.74, east: -1.39, north: 50.76 };
  const wide = windFieldGeoJson(
    [{ longitude: -1, latitude: 51 }], response, wideBounds, at, 6, 4,
  );
  const close = windFieldGeoJson(
    [{ longitude: -1.4, latitude: 50.75 }], response, closeBounds, at, 10, 7,
  );
  const length = (field) => {
    const [start, end] = field.geojson.features[0].geometry.coordinates[0];
    return Math.hypot(end[0] - start[0], end[1] - start[1]);
  };
  assert.ok(length(close) < length(wide) / 20);

  const marineResponse = {
    hourly: {
      time: ["2026-08-21T14:00", "2026-08-21T15:00"],
      ocean_current_velocity: [1, 1],
      ocean_current_direction: [90, 90],
      sea_level_height_msl: [0, 0],
    },
  };
  const wideCurrent = currentFieldGeoJson(
    [{ longitude: -1, latitude: 51 }], marineResponse, wideBounds, at, 5, 3,
  );
  const closeCurrent = currentFieldGeoJson(
    [{ longitude: -1.4, latitude: 50.75 }], marineResponse, closeBounds, at, 10, 7,
  );
  assert.ok(length(closeCurrent) < length(wideCurrent) / 20);
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

test("renders deduplicated currents at the model's selected sea cells", () => {
  const bounds = { west: -1.6, south: 50.7, east: -1.0, north: 50.9 };
  const points = marineGrid(bounds, 2, 1);
  const response = points.map(() => ({
    latitude: 50.7917,
    longitude: -1.375,
    hourly: {
      time: ["2026-08-21T14:00", "2026-08-21T15:00"],
      ocean_current_velocity: [1, 1],
      ocean_current_direction: [90, 90],
      sea_level_height_msl: [0, 0],
    },
  }));
  const field = currentFieldGeoJson(
    points,
    response,
    bounds,
    [
      { sampleTime: new Date("2026-08-21T14:30:00Z"), forecastWeight: 0 },
      { sampleTime: new Date("2026-08-21T14:30:00Z"), forecastWeight: 1 },
    ],
    2,
    1,
  );
  assert.equal(field.samples.length, 1);
  assert.equal(field.samples[0].forecastWeight, 1);
  assert.equal(field.geojson.features.length, 2);
  assert.deepEqual(field.geojson.features[1].geometry.coordinates, [-1.375, 50.7917]);
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

test("derives model high and low water events for the tide table", () => {
  const start = new Date("2026-08-21T00:00:00Z");
  const end = new Date("2026-08-21T08:00:00Z");
  assert.match(tideRequestUrl({ latitude: 50.75, longitude: -1.4 }, start, end), /sea_level_height_msl/);
  const response = {
    hourly: {
      time: Array.from({ length: 9 }, (_, index) => `2026-08-21T${String(index).padStart(2, "0")}:00`),
      sea_level_height_msl: [0, 1, 2, 1, 0, -1, -2, -1, 0],
    },
  };
  const events = tideEventsFromResponse(response, start, end);
  const series = tideSeriesFromResponse(response, start, end);
  assert.deepEqual(events.map((event) => event.kind), ["high", "low"]);
  assert.equal(events[0].time, "2026-08-21T02:00:00.000Z");
  assert.equal(events[1].heightMsl, -2);
  assert.equal(series.length, 9);
  assert.equal(tideLevelAt(series, new Date("2026-08-21T01:30:00Z")), 1.5);
});

test("deduplicates and reuses forecast requests", async () => {
  clearForecastCache();
  let requests = 0;
  const fetcher = async () => {
    requests += 1;
    await Promise.resolve();
    return { ok: true, status: 200, json: async () => ({ value: 42 }) };
  };
  const options = { fetcher, now: () => 1_000, ttlMs: 60_000 };
  const [first, second] = await Promise.all([
    fetchForecastJson("https://example.test/forecast", options),
    fetchForecastJson("https://example.test/forecast", options),
  ]);
  const cached = await fetchForecastJson("https://example.test/forecast", options);
  assert.equal(requests, 1);
  assert.deepEqual(first.data, { value: 42 });
  assert.deepEqual(second.data, first.data);
  assert.equal(cached.cacheStatus, "fresh-cache");
});

test("uses stale forecast data during a 429 cooldown", async () => {
  clearForecastCache();
  let currentTime = 1_000;
  const url = "https://example.test/rate-limited";
  await fetchForecastJson(url, {
    now: () => currentTime,
    fetcher: async () => ({ ok: true, status: 200, json: async () => ({ height: 1.2 }) }),
    ttlMs: 10,
  });
  currentTime = 2_000;
  let rateLimitedRequests = 0;
  const options = {
    now: () => currentTime,
    ttlMs: 10,
    staleIfErrorMs: 60_000,
    fetcher: async () => {
      rateLimitedRequests += 1;
      return {
        ok: false,
        status: 429,
        headers: { get: () => "90" },
        json: async () => ({}),
      };
    },
  };
  const fallback = await fetchForecastJson(url, options);
  const cooldownFallback = await fetchForecastJson(url, options);
  await assert.rejects(
    fetchForecastJson("https://example.test/another-forecast", options),
    /forecast service rate limited/,
  );
  assert.equal(fallback.cacheStatus, "stale-cache");
  assert.equal(cooldownFallback.cacheStatus, "stale-cache");
  assert.equal(rateLimitedRequests, 1);
});

test("builds a daylight chart and flags arrival after sunset", () => {
  assert.match(sunRequestUrl({ latitude: 50.75, longitude: -1.4 }), /daily=sunrise%2Csunset/);
  const epoch = (value) => Date.parse(value) / 1000;
  const chart = sunChartRows(
    {
      timezone: "Europe/London",
      timezone_abbreviation: "BST",
      utc_offset_seconds: 0,
      daily: {
        time: [epoch("2026-08-21T00:00:00Z"), epoch("2026-08-22T00:00:00Z")],
        sunrise: [epoch("2026-08-21T06:00:00Z"), epoch("2026-08-22T06:01:00Z")],
        sunset: [epoch("2026-08-21T18:00:00Z"), epoch("2026-08-22T17:58:00Z")],
      },
    },
    new Date("2026-08-21T08:00:00Z"),
    new Date("2026-08-21T19:00:00Z"),
  );
  assert.equal(chart.rows.length, 1);
  assert.equal(chart.rows[0].sunriseLabel, "07:00");
  assert.equal(chart.rows[0].arrivalAfterSunset, true);
  assert.ok(Math.abs(chart.rows[0].startPercent - 100 / 3) < 1e-9);
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

test("plots repeated course-to-steer arrows without an ambiguous drift track", () => {
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
  const geojson = routeCurrentGeoJson(estimate);
  assert.equal(
    geojson.features.filter((feature) => feature.properties.kind === "course-to-steer-arrow").length,
    samplePlan.length,
  );
  assert.equal(
    geojson.features.filter((feature) => feature.properties.kind === "drift-line").length,
    0,
  );
});
