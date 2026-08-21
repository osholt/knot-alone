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

export function windRequestUrl(points) {
  const parameters = new URLSearchParams({
    latitude: points.map((point) => point.latitude.toFixed(4)).join(","),
    longitude: points.map((point) => point.longitude.toFixed(4)).join(","),
    current: "wind_speed_10m,wind_direction_10m,wind_gusts_10m",
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

export function windFieldGeoJson(points, response, bounds, columns = 6, rows = 4) {
  const values = Array.isArray(response) ? response : [response];
  const arrowLength = Math.max(
    0.004,
    Math.min((bounds.north - bounds.south) / rows, (bounds.east - bounds.west) / columns) * 0.28,
  );
  const features = [];
  let validTime = null;
  values.slice(0, points.length).forEach((value, index) => {
    const current = value?.current;
    if (
      ![current?.wind_speed_10m, current?.wind_direction_10m, current?.wind_gusts_10m].every(
        Number.isFinite,
      )
    ) return;
    const point = points[index];
    const downwind = (current.wind_direction_10m + 180) % 360;
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
    const properties = {
      speedKnots: current.wind_speed_10m,
      speedLabel: `${Math.round(current.wind_speed_10m)} kn`,
      directionFrom: current.wind_direction_10m,
      gustKnots: current.wind_gusts_10m,
      validTime: current.time,
    };
    validTime ||= current.time;
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
