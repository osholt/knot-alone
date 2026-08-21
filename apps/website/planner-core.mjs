const EARTH_RADIUS_METRES = 6_371_000;
const METRES_PER_NAUTICAL_MILE = 1852;

const XML_ENTITIES = Object.freeze({
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&apos;",
});

export function escapeXml(value) {
  return String(value).replace(/[&<>"']/g, (character) => XML_ENTITIES[character]);
}

export function gpxFileName(passageName) {
  const slug = String(passageName)
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return `${slug || "tide-and-seek-passage"}.gpx`;
}

export function formatDistance(metres) {
  if (!Number.isFinite(metres) || metres < 0) return "—";
  const nauticalMiles = metres / METRES_PER_NAUTICAL_MILE;
  return `${nauticalMiles < 10 ? nauticalMiles.toFixed(1) : nauticalMiles.toFixed(0)} NM`;
}

export function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "—";
  const totalMinutes = Math.round(seconds / 60);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours === 0) return `${minutes} min`;
  return minutes === 0 ? `${hours} hr` : `${hours} hr ${minutes} min`;
}

export function formatBearing(degrees) {
  if (!Number.isFinite(degrees)) return "—";
  return `${String(Math.round(normalizeBearing(degrees))).padStart(3, "0")}°T`;
}

export function rhumbLeg(first, second) {
  validateCoordinate(first.longitude, first.latitude);
  validateCoordinate(second.longitude, second.latitude);

  const radians = Math.PI / 180;
  const degrees = 180 / Math.PI;
  const latitude1 = first.latitude * radians;
  const latitude2 = second.latitude * radians;
  const deltaLatitude = latitude2 - latitude1;
  let deltaLongitude = (second.longitude - first.longitude) * radians;
  if (Math.abs(deltaLongitude) > Math.PI) {
    deltaLongitude = deltaLongitude > 0
      ? -(2 * Math.PI - deltaLongitude)
      : 2 * Math.PI + deltaLongitude;
  }
  const deltaMeridional = Math.log(
    Math.tan(Math.PI / 4 + latitude2 / 2) /
      Math.tan(Math.PI / 4 + latitude1 / 2),
  );
  const q = Math.abs(deltaMeridional) > 1e-12
    ? deltaLatitude / deltaMeridional
    : Math.cos(latitude1);
  const distanceMetres = Math.sqrt(
    deltaLatitude ** 2 + (q * deltaLongitude) ** 2,
  ) * EARTH_RADIUS_METRES;
  const bearingDegrees = normalizeBearing(
    Math.atan2(deltaLongitude, deltaMeridional) * degrees,
  );
  return { distanceMetres, bearingDegrees };
}

export function passageSummary(stops, speedKnots = 5) {
  if (!Array.isArray(stops) || stops.length < 2) {
    return { distanceMetres: 0, durationSeconds: 0, legs: [] };
  }
  const safeSpeed = Number(speedKnots);
  const legs = [];
  let distanceMetres = 0;
  for (let index = 1; index < stops.length; index += 1) {
    const leg = rhumbLeg(stops[index - 1], stops[index]);
    distanceMetres += leg.distanceMetres;
    legs.push({
      index,
      from: stops[index - 1],
      to: stops[index],
      ...leg,
    });
  }
  const durationSeconds = Number.isFinite(safeSpeed) && safeSpeed > 0
    ? (distanceMetres / METRES_PER_NAUTICAL_MILE / safeSpeed) * 3600
    : null;
  return { distanceMetres, durationSeconds, legs };
}

export function buildGpx({ passageName, stops, createdAt = new Date() }) {
  const safeName = String(passageName).trim();
  if (!safeName) throw new Error("Name the passage before exporting it.");
  if (!Array.isArray(stops) || stops.length < 2) {
    throw new Error("Add at least two waypoints before exporting the GPX file.");
  }

  const timestamp = (createdAt instanceof Date ? createdAt : new Date(createdAt))
    .toISOString();
  const routePoints = stops.map((stop, index) => {
    validateCoordinate(stop.longitude, stop.latitude);
    const name = String(stop.name || `Waypoint ${index + 1}`).trim();
    const description = String(stop.notes || "").trim();
    return [
      `    <rtept lat="${formatCoordinate(stop.latitude)}" lon="${formatCoordinate(stop.longitude)}">`,
      `      <name>${escapeXml(name)}</name>`,
      description ? `      <desc>${escapeXml(description)}</desc>` : null,
      "      <sym>Waypoint</sym>",
      "    </rtept>",
    ].filter(Boolean).join("\n");
  }).join("\n");
  const waypoints = stops.map((stop, index) => {
    const name = String(stop.name || `Waypoint ${index + 1}`).trim();
    return [
      `  <wpt lat="${formatCoordinate(stop.latitude)}" lon="${formatCoordinate(stop.longitude)}">`,
      `    <name>${escapeXml(name)}</name>`,
      "    <sym>Waypoint</sym>",
      "  </wpt>",
    ].join("\n");
  }).join("\n");

  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<gpx version="1.1" creator="Tide and Seek passage planner" xmlns="http://www.topografix.com/GPX/1/1">',
    "  <metadata>",
    `    <name>${escapeXml(safeName)}</name>`,
    "    <desc>User-drawn rhumb-line passage plan. Check against current official charts and publications.</desc>",
    `    <time>${timestamp}</time>`,
    "  </metadata>",
    waypoints,
    "  <rte>",
    `    <name>${escapeXml(safeName)}</name>`,
    routePoints,
    "  </rte>",
    "</gpx>",
    "",
  ].join("\n");
}

export function parseGpxDocument(document) {
  const root = document?.documentElement;
  if (!root || localName(root) !== "gpx") {
    throw new Error("The document root must be <gpx>.");
  }
  const parserError = document.querySelector?.("parsererror");
  if (parserError) throw new Error("Invalid GPX XML.");

  const route = descendants(root, "rte")[0];
  const routePoints = route ? descendants(route, "rtept") : [];
  const waypoints = descendants(root, "wpt");
  const trackPoints = descendants(root, "trkpt");
  const candidates = routePoints.length > 0
    ? routePoints
    : waypoints.length > 1
      ? waypoints
      : trackPoints;
  if (candidates.length < 2) {
    throw new Error("The GPX file must contain at least two route, track or waypoint positions.");
  }
  const stops = candidates.map((node, index) => {
    const latitude = Number(node.getAttribute("lat"));
    const longitude = Number(node.getAttribute("lon"));
    validateCoordinate(longitude, latitude);
    return {
      id: index + 1,
      name: childText(node, "name") || `Waypoint ${index + 1}`,
      notes: childText(node, "desc") || "",
      latitude,
      longitude,
    };
  });
  const metadata = descendants(root, "metadata")[0];
  const name = childText(metadata, "name") || childText(route, "name") || "Imported passage";
  return { name, stops };
}

function normalizeBearing(value) {
  return ((value % 360) + 360) % 360;
}

function validateCoordinate(longitude, latitude) {
  if (
    !Number.isFinite(Number(longitude)) ||
    !Number.isFinite(Number(latitude)) ||
    Number(longitude) < -180 ||
    Number(longitude) > 180 ||
    Number(latitude) < -90 ||
    Number(latitude) > 90
  ) {
    throw new Error("The passage contains an invalid coordinate.");
  }
}

function formatCoordinate(value) {
  return Number(value).toFixed(7);
}

function localName(node) {
  return String(node?.localName || node?.nodeName || "").toLowerCase();
}

function descendants(parent, name) {
  if (!parent) return [];
  return Array.from(parent.getElementsByTagNameNS?.("*", name) || parent.getElementsByTagName(name));
}

function childText(parent, name) {
  if (!parent) return null;
  const child = Array.from(parent.children || []).find((item) => localName(item) === name);
  const value = child?.textContent?.trim();
  return value || null;
}
