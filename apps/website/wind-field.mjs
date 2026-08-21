const OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast";

export function windGrid(bounds, columns = 6, rows = 4) {
  if (!bounds || bounds.east <= bounds.west || bounds.north <= bounds.south) return [];
  const points = [];
  for (let row = 0; row < rows; row += 1) {
    for (let column = 0; column < columns; column += 1) {
      points.push({
        longitude: bounds.west + ((column + 0.5) / columns) * (bounds.east - bounds.west),
        latitude: bounds.south + ((row + 0.5) / rows) * (bounds.north - bounds.south),
      });
    }
  }
  return points;
}

export function windRequestUrl(points, start = new Date(), end = start) {
  if (!Array.isArray(points) || points.length === 0) {
    throw new Error("At least one wind-model position is required.");
  }
  const startDate = validDate(start);
  const endDate = validDate(end);
  if (endDate < startDate) throw new Error("The wind-model time range is invalid.");
  const parameters = new URLSearchParams({
    latitude: points.map((point) => point.latitude.toFixed(4)).join(","),
    longitude: points.map((point) => point.longitude.toFixed(4)).join(","),
    hourly: "wind_speed_10m,wind_direction_10m,wind_gusts_10m",
    start_hour: formatUtcHour(new Date(Math.floor(startDate.getTime() / 3_600_000) * 3_600_000)),
    end_hour: formatUtcHour(new Date(Math.ceil(endDate.getTime() / 3_600_000) * 3_600_000)),
    wind_speed_unit: "kn",
    timezone: "UTC",
  });
  return `${OPEN_METEO_URL}?${parameters}`;
}

function offsetPoint(point, bearingDegrees, distanceLatitudeDegrees) {
  const radians = (bearingDegrees * Math.PI) / 180;
  const latitude = point.latitude + Math.cos(radians) * distanceLatitudeDegrees;
  const longitude =
    point.longitude +
    (Math.sin(radians) * distanceLatitudeDegrees) /
      Math.max(0.2, Math.cos((point.latitude * Math.PI) / 180));
  return [longitude, latitude];
}

export function sampleWindAt(response, at) {
  const target = validDate(at).getTime();
  const hourly = response?.hourly;
  const times = Array.isArray(hourly?.time)
    ? hourly.time.map((value) => Date.parse(`${value}Z`))
    : [];
  if (times.length === 0 || times.some((value) => !Number.isFinite(value))) return null;
  let upper = times.findIndex((value) => value >= target);
  if (upper < 0) upper = times.length - 1;
  const lower = Math.max(0, upper - (times[upper] > target ? 1 : 0));
  const span = times[upper] - times[lower];
  const fraction = span > 0 ? Math.max(0, Math.min(1, (target - times[lower]) / span)) : 0;
  const first = windVector(hourly, lower);
  const second = windVector(hourly, upper);
  if (!first || !second) return null;
  const eastFrom = first.eastFrom + (second.eastFrom - first.eastFrom) * fraction;
  const northFrom = first.northFrom + (second.northFrom - first.northFrom) * fraction;
  return {
    speedKnots: Math.hypot(eastFrom, northFrom),
    directionFrom: normalizeBearing((Math.atan2(eastFrom, northFrom) * 180) / Math.PI),
    gustKnots: first.gustKnots + (second.gustKnots - first.gustKnots) * fraction,
    validTime: new Date(target).toISOString(),
  };
}

export function windFieldGeoJson(
  points,
  response,
  bounds,
  atOrTimings = new Date(),
  columns = 6,
  rows = 4,
) {
  const values = Array.isArray(response) ? response : [response];
  const arrowLength = Math.max(
    0.00002,
    Math.min((bounds.north - bounds.south) / rows, (bounds.east - bounds.west) / columns) * 0.24,
  );
  const features = [];
  let validTime = null;
  values.slice(0, points.length).forEach((value, index) => {
    const requestedTiming = Array.isArray(atOrTimings)
      ? atOrTimings[index]
      : { sampleTime: atOrTimings, forecastWeight: 0, timing: "current" };
    const sample = sampleWindAt(value, requestedTiming?.sampleTime);
    if (!sample) return;
    const point = points[index];
    const downwind = (sample.directionFrom + 180) % 360;
    const start = offsetPoint(point, (downwind + 180) % 360, arrowLength * 0.48);
    const end = offsetPoint(point, downwind, arrowLength * 0.48);
    const leftHead = offsetPoint(
      { longitude: end[0], latitude: end[1] },
      (downwind + 150) % 360,
      arrowLength * 0.32,
    );
    const rightHead = offsetPoint(
      { longitude: end[0], latitude: end[1] },
      (downwind + 210) % 360,
      arrowLength * 0.32,
    );
    const forecastWeight = Math.max(0, Math.min(1, Number(requestedTiming.forecastWeight) || 0));
    const timeLabel = forecastWeight < 0.01
      ? "now"
      : new Date(sample.validTime).toISOString().slice(11, 16) + "Z";
    const properties = {
      speedKnots: sample.speedKnots,
      speedLabel: `${Math.round(sample.speedKnots)} kn · ${timeLabel}`,
      directionFrom: sample.directionFrom,
      gustKnots: sample.gustKnots,
      validTime: sample.validTime,
      forecastWeight,
      timing: requestedTiming?.timing || "current",
    };
    validTime ||= sample.validTime;
    features.push({
      type: "Feature",
      properties: { ...properties, kind: "arrow" },
      geometry: {
        type: "MultiLineString",
        coordinates: [[start, end], [end, leftHead], [end, rightHead]],
      },
    });
    features.push({
      type: "Feature",
      properties: { ...properties, kind: "label" },
      geometry: { type: "Point", coordinates: [point.longitude, point.latitude] },
    });
  });
  return { geojson: { type: "FeatureCollection", features }, validTime };
}

function windVector(hourly, index) {
  const speedKnots = Number(hourly?.wind_speed_10m?.[index]);
  const directionFrom = Number(hourly?.wind_direction_10m?.[index]);
  const gustKnots = Number(hourly?.wind_gusts_10m?.[index]);
  if (![speedKnots, directionFrom, gustKnots].every(Number.isFinite)) return null;
  const radians = (directionFrom * Math.PI) / 180;
  return {
    eastFrom: speedKnots * Math.sin(radians),
    northFrom: speedKnots * Math.cos(radians),
    gustKnots,
  };
}

function formatUtcHour(date) {
  return date.toISOString().slice(0, 13) + ":00";
}

function validDate(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error("Choose a valid forecast time.");
  return date;
}

function normalizeBearing(value) {
  return ((value % 360) + 360) % 360;
}
