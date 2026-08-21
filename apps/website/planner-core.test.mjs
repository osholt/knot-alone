import test from "node:test";
import assert from "node:assert/strict";

import {
  buildGpx,
  escapeXml,
  formatBearing,
  formatDistance,
  formatDuration,
  gpxFileName,
  passageSummary,
  rhumbLeg,
} from "./planner-core.mjs";
import {
  decodePlannerDraft,
  encodePlannerDraft,
} from "./planner-storage.mjs";

const lymington = { id: 1, name: "Lymington", latitude: 50.7403, longitude: -1.5071 };
const cowes = { id: 2, name: "Cowes", latitude: 50.7623, longitude: -1.2982 };

test("uses nautical units and true bearings for passage legs", () => {
  const leg = rhumbLeg(lymington, cowes);
  assert.ok(leg.distanceMetres > 14_000 && leg.distanceMetres < 15_500);
  assert.ok(leg.bearingDegrees > 75 && leg.bearingDegrees < 85);
  assert.match(formatDistance(leg.distanceMetres), /NM$/);
  assert.match(formatBearing(leg.bearingDegrees), /^0?\d{2}°T$/);
});

test("summarises a multi-leg passage using an explicit speed assumption", () => {
  const summary = passageSummary([
    lymington,
    cowes,
    { id: 3, name: "Hamble", latitude: 50.86, longitude: -1.31 },
  ], 5);
  assert.equal(summary.legs.length, 2);
  assert.ok(summary.distanceMetres > 20_000);
  assert.ok(summary.durationSeconds > 2 * 60 * 60);
  assert.notEqual(formatDuration(summary.durationSeconds), "—");
});

test("exports Tide and Seek GPX with route waypoints and safety wording", () => {
  const gpx = buildGpx({
    passageName: "Solent & back",
    stops: [lymington, { ...cowes, notes: "Check tidal gate < 2 kn" }],
    createdAt: new Date("2026-08-21T12:00:00Z"),
  });
  assert.match(gpx, /creator="Tide and Seek passage planner"/);
  assert.match(gpx, /<rte>/);
  assert.match(gpx, /<wpt lat=/);
  assert.match(gpx, /Check tidal gate &lt; 2 kn/);
  assert.match(gpx, /official charts and publications/);
});

test("escapes XML and produces a stable GPX file name", () => {
  assert.equal(escapeXml("A & <B>"), "A &amp; &lt;B&gt;");
  assert.equal(gpxFileName("Solent & Back"), "solent-back.gpx");
});

test("round-trips a bounded local planner draft", () => {
  const serialized = encodePlannerDraft({
    passageName: "Saturday passage",
    speedKnots: 5.5,
    startTime: "2026-08-22T08:30:00.000Z",
    stops: [lymington, cowes],
    bathymetrySource: "gebco",
    bathymetryVisible: true,
    gebcoVisible: true,
    depthPalette: "high-contrast",
    shallowContoursVisible: false,
    offshoreContoursVisible: true,
    noaaVisible: true,
    seamarksVisible: true,
    windVisible: true,
    currentVisible: true,
    poiCategories: ["marina", "anchorage"],
  }, 1000);
  const draft = decodePlannerDraft(serialized, { now: 2000 });
  assert.equal(draft.passageName, "Saturday passage");
  assert.equal(draft.stops.length, 2);
  assert.equal(draft.startTime, "2026-08-22T08:30:00.000Z");
  assert.equal(draft.bathymetrySource, "gebco");
  assert.equal(draft.bathymetryVisible, true);
  assert.equal(draft.gebcoVisible, true);
  assert.equal(draft.depthPalette, "high-contrast");
  assert.equal(draft.shallowContoursVisible, false);
  assert.equal(draft.offshoreContoursVisible, true);
  assert.equal(draft.noaaVisible, true);
  assert.equal(draft.windVisible, true);
  assert.equal(draft.currentVisible, true);
  assert.deepEqual(draft.poiCategories, ["marina", "anchorage"]);
});

test("rejects expired or invalid local drafts", () => {
  assert.equal(decodePlannerDraft("not-json"), null);
  const expired = encodePlannerDraft({ passageName: "Old", stops: [] }, 1);
  assert.equal(decodePlannerDraft(expired, { now: 10_000, maxAge: 100 }), null);
});

test("enables shallow contours when migrating an older planner draft", () => {
  const serialized = encodePlannerDraft({
    passageName: "Older passage",
    stops: [],
    contoursVisible: true,
  }, 1000);
  const draft = decodePlannerDraft(serialized, { now: 2000 });
  assert.equal(draft.shallowContoursVisible, true);
  assert.equal(draft.offshoreContoursVisible, true);
});
