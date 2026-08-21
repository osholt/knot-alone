const MARINE_API_URL = "https://marine-api.open-meteo.com/v1/marine";
const METRES_PER_NAUTICAL_MILE = 1852;

export const SOLENT_TIDE_DATUMS = Object.freeze([
  Object.freeze({
    id: "lymington-lym-gbr-cco",
    name: "Lymington",
    latitude: 50.7403,
    longitude: -1.50714,
    chartDatum: "LAT",
    mslAboveChartDatumM: 2.136 - 0.18,
  }),
  Object.freeze({
    id: "portsmouth-ptm-gbr-bodc",
    name: "Portsmouth",
    latitude: 50.802194,
    longitude: -1.11125,
    chartDatum: "LAT",
    mslAboveChartDatumM: 2.927 - 0.325,
  }),
  Object.freeze({
    id: "southampton-sou-gbr-da_idh",
    name: "Southampton",
    latitude: 50.8839,
    longitude: -1.3931,
    chartDatum: "LAT",
    mslAboveChartDatumM: 2.835 - 0.066,
  }),
]);

export function marineGrid(bounds, columns = 5, rows = 3) {
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

export function currentGridDimensions(widthPixels, heightPixels, zoom) {
  const width = Math.max(320, Number(widthPixels) || 0);
  const height = Math.max(240, Number(heightPixels) || 0);
  const level = Number.isFinite(Number(zoom)) ? Number(zoom) : 8;
  const targetSpacing = Math.max(105, Math.min(220, 220 - (level - 4) * 12));
  return {
    columns: Math.max(3, Math.min(10, Math.round(width / targetSpacing))),
    rows: Math.max(2, Math.min(7, Math.round(height / targetSpacing))),
  };
}

export function marineRequestUrl(points, start, end) {
  if (!Array.isArray(points) || points.length === 0) {
    throw new Error("At least one marine-model position is required.");
  }
  const startDate = validDate(start);
  const endDate = validDate(end);
  if (endDate < startDate) throw new Error("The marine-model time range is invalid.");
  const startHour = new Date(Math.floor(startDate.getTime() / 3_600_000) * 3_600_000);
  const endHour = new Date(Math.ceil(endDate.getTime() / 3_600_000) * 3_600_000);
  const parameters = new URLSearchParams({
    latitude: points.map((point) => Number(point.latitude).toFixed(4)).join(","),
    longitude: points.map((point) => Number(point.longitude).toFixed(4)).join(","),
    hourly: "ocean_current_velocity,ocean_current_direction,sea_level_height_msl",
    start_hour: formatUtcHour(startHour),
    end_hour: formatUtcHour(endHour),
    wind_speed_unit: "kn",
    timezone: "UTC",
    cell_selection: "sea",
  });
  return `${MARINE_API_URL}?${parameters}`;
}

export function sampleMarineAt(response, at) {
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
  const first = marineVector(hourly, lower);
  const second = marineVector(hourly, upper);
  if (!first || !second) return null;
  const eastKnots = first.eastKnots + (second.eastKnots - first.eastKnots) * fraction;
  const northKnots = first.northKnots + (second.northKnots - first.northKnots) * fraction;
  const speedKnots = Math.hypot(eastKnots, northKnots);
  const directionTowards = normalizeBearing((Math.atan2(eastKnots, northKnots) * 180) / Math.PI);
  const seaLevelMsl = interpolateNullable(first.seaLevelMsl, second.seaLevelMsl, fraction);
  return {
    speedKnots,
    directionTowards,
    seaLevelMsl,
    validTime: new Date(target).toISOString(),
  };
}

export function currentFieldGeoJson(
  points,
  response,
  bounds,
  atOrTimings,
  columns = 5,
  rows = 3,
) {
  const values = Array.isArray(response) ? response : [response];
  const arrowLength = Math.max(
    0.00008,
    Math.min((bounds.north - bounds.south) / rows, (bounds.east - bounds.west) / columns) * 0.32,
  );
  const features = [];
  const samples = [];
  values.slice(0, points.length).forEach((value, index) => {
    const requestedTiming = Array.isArray(atOrTimings)
      ? atOrTimings[index]
      : { sampleTime: atOrTimings, forecastWeight: 0, timing: "passage-start" };
    const sample = sampleMarineAt(value, requestedTiming?.sampleTime);
    if (!sample) return;
    const forecastWeight = Math.max(0, Math.min(1, Number(requestedTiming.forecastWeight) || 0));
    samples.push({ ...sample, point: points[index], index, ...requestedTiming, forecastWeight });
    const properties = {
      kind: "current-arrow",
      speedKnots: sample.speedKnots,
      speedLabel: `${sample.speedKnots.toFixed(1)} kn`,
      directionTowards: sample.directionTowards,
      seaLevelMsl: sample.seaLevelMsl,
      validTime: sample.validTime,
      timing: requestedTiming?.timing || "current",
      forecastWeight,
      routeDistanceNm: requestedTiming?.routeDistanceNm ?? null,
      routeTime: requestedTiming?.routeTime ?? null,
    };
    features.push(arrowFeature(points[index], sample.directionTowards, arrowLength, properties));
    features.push({
      type: "Feature",
      properties: { ...properties, kind: "current-label" },
      geometry: { type: "Point", coordinates: [points[index].longitude, points[index].latitude] },
    });
  });
  return { geojson: { type: "FeatureCollection", features }, samples };
}

export function routeSamplePlan(summary, { spacingNm = 2.5, maximumSamples = 60 } = {}) {
  if (!Array.isArray(summary?.legs)) return [];
  const totalDistanceNm = summary.legs.reduce(
    (total, leg) => total + Number(leg.distanceMetres || 0) / METRES_PER_NAUTICAL_MILE,
    0,
  );
  const effectiveSpacing = Math.max(spacingNm, totalDistanceNm / maximumSamples);
  return summary.legs.flatMap((leg) => {
    const distanceNm = Number(leg.distanceMetres) / METRES_PER_NAUTICAL_MILE;
    const count = Math.max(1, Math.ceil(distanceNm / effectiveSpacing));
    return Array.from({ length: count }, (_, sampleIndex) => {
      const fraction = (sampleIndex + 0.5) / count;
      return {
        legIndex: leg.index,
        sampleIndex,
        sampleCount: count,
        fraction,
        distanceMetres: Number(leg.distanceMetres) / count,
        point: interpolateCoordinate(leg.from, leg.to, fraction),
      };
    });
  });
}

export function currentSampleTimings(
  points,
  now,
  estimate,
  { innerDistanceNm = 1.5, outerDistanceNm = 8 } = {},
) {
  const currentTime = validDate(now);
  if (!Array.isArray(estimate?.legs) || estimate.legs.length === 0) {
    return points.map(() => ({
      sampleTime: currentTime,
      routeTime: null,
      routeDistanceNm: null,
      forecastWeight: 0,
      timing: "current",
    }));
  }
  return points.map((point) => {
    const nearest = estimate.legs
      .map((leg) => nearestPointOnLeg(point, leg))
      .sort((first, second) => first.distanceNm - second.distanceNm)[0];
    const legStart = validDate(nearest.leg.startTime || estimate.startTime);
    const legEnd = validDate(nearest.leg.arrivalTime);
    const routeTime = new Date(
      legStart.getTime() + (legEnd.getTime() - legStart.getTime()) * nearest.fraction,
    );
    const linearWeight = outerDistanceNm > innerDistanceNm
      ? (outerDistanceNm - nearest.distanceNm) / (outerDistanceNm - innerDistanceNm)
      : Number(nearest.distanceNm <= innerDistanceNm);
    const boundedWeight = Math.max(0, Math.min(1, linearWeight));
    const forecastWeight = boundedWeight * boundedWeight * (3 - 2 * boundedWeight);
    const sampleTime = new Date(
      currentTime.getTime() + (routeTime.getTime() - currentTime.getTime()) * forecastWeight,
    );
    return {
      sampleTime,
      routeTime: routeTime.toISOString(),
      routeDistanceNm: nearest.distanceNm,
      forecastWeight,
      timing: forecastWeight < 0.01
        ? "current"
        : forecastWeight > 0.99 ? "expected-route" : "blended-route",
    };
  });
}

export function estimatePassageWithCurrents(
  summary,
  responses,
  start,
  boatSpeedKnots,
  samplePlan = routeSamplePlan(summary),
) {
  const startDate = validDate(start);
  const speed = Number(boatSpeedKnots);
  if (!Number.isFinite(speed) || speed <= 0 || !Array.isArray(summary?.legs)) return null;
  const values = Array.isArray(responses) ? responses : [responses];
  const legs = [];
  let elapsedSeconds = 0;
  let complete = true;
  let driftPosition = summary.legs[0]?.from
    ? { longitude: summary.legs[0].from.longitude, latitude: summary.legs[0].from.latitude }
    : null;
  const driftCoordinates = driftPosition
    ? [[driftPosition.longitude, driftPosition.latitude]]
    : [];

  summary.legs.forEach((leg) => {
    const legStartSeconds = elapsedSeconds;
    const stillDurationSeconds = (leg.distanceMetres / METRES_PER_NAUTICAL_MILE / speed) * 3600;
    const plannedSamples = samplePlan.filter((value) => value.legIndex === leg.index);
    const samples = [];
    let legDurationSeconds = 0;
    let weightedEast = 0;
    let weightedNorth = 0;
    let weightedSeaLevel = 0;
    let seaLevelWeight = 0;
    plannedSamples.forEach((planned) => {
      const responseIndex = samplePlan.indexOf(planned);
      const sampleStillSeconds =
        (planned.distanceMetres / METRES_PER_NAUTICAL_MILE / speed) * 3600;
      let durationSeconds = sampleStillSeconds;
      let sample = null;
      let effect = null;
      for (let pass = 0; pass < 3; pass += 1) {
        const midpoint = new Date(
          startDate.getTime() + (elapsedSeconds + durationSeconds / 2) * 1000,
        );
        sample = sampleMarineAt(values[responseIndex], midpoint);
        effect = sample
          ? currentEffect(speed, leg.bearingDegrees, sample.speedKnots, sample.directionTowards)
          : null;
        if (!effect) break;
        durationSeconds =
          (planned.distanceMetres / METRES_PER_NAUTICAL_MILE / effect.effectiveSpeedKnots) * 3600;
      }
      if (!sample || !effect || !Number.isFinite(durationSeconds)) complete = false;
      const usedDuration = effect ? durationSeconds : sampleStillSeconds;
      const midpointTime = new Date(
        startDate.getTime() + (elapsedSeconds + usedDuration / 2) * 1000,
      );
      elapsedSeconds += usedDuration;
      legDurationSeconds += usedDuration;
      if (sample) {
        const radians = (sample.directionTowards * Math.PI) / 180;
        weightedEast += sample.speedKnots * Math.sin(radians) * usedDuration;
        weightedNorth += sample.speedKnots * Math.cos(radians) * usedDuration;
        if (Number.isFinite(sample.seaLevelMsl)) {
          weightedSeaLevel += sample.seaLevelMsl * usedDuration;
          seaLevelWeight += usedDuration;
        }
      }
      if (sample && driftPosition) {
        const delta = ((sample.directionTowards - leg.bearingDegrees) * Math.PI) / 180;
        const alongSpeed = speed + sample.speedKnots * Math.cos(delta);
        const driftHours = planned.distanceMetres / METRES_PER_NAUTICAL_MILE /
          Math.max(0.1, alongSpeed);
        driftPosition = displaceByVelocity(
          driftPosition,
          speed,
          leg.bearingDegrees,
          sample.speedKnots,
          sample.directionTowards,
          driftHours,
        );
        driftCoordinates.push([driftPosition.longitude, driftPosition.latitude]);
      }
      samples.push({
        ...planned,
        midpointTime: midpointTime.toISOString(),
        arrivalTime: new Date(startDate.getTime() + elapsedSeconds * 1000).toISOString(),
        currentSpeedKnots: sample?.speedKnots ?? null,
        currentDirectionTowards: sample?.directionTowards ?? null,
        seaLevelMsl: sample?.seaLevelMsl ?? null,
        adjustedDurationSeconds: effect ? durationSeconds : null,
        ...effect,
      });
    });
    const vectorWeight = Math.max(1, legDurationSeconds);
    const averageEast = weightedEast / vectorWeight;
    const averageNorth = weightedNorth / vectorWeight;
    const currentSpeedKnots = Math.hypot(averageEast, averageNorth);
    const currentDirectionTowards = normalizeBearing(
      (Math.atan2(averageEast, averageNorth) * 180) / Math.PI,
    );
    const aggregateEffect = currentEffect(
      speed,
      leg.bearingDegrees,
      currentSpeedKnots,
      currentDirectionTowards,
    );
    legs.push({
      ...leg,
      startTime: new Date(startDate.getTime() + legStartSeconds * 1000).toISOString(),
      midpoint: midpointCoordinate(leg.from, leg.to),
      midpointTime: new Date(
        startDate.getTime() + (legStartSeconds + legDurationSeconds / 2) * 1000,
      ).toISOString(),
      arrivalTime: new Date(startDate.getTime() + elapsedSeconds * 1000).toISOString(),
      stillDurationSeconds,
      adjustedDurationSeconds: samples.every((sample) => sample.adjustedDurationSeconds !== null)
        ? legDurationSeconds
        : null,
      currentSpeedKnots,
      currentDirectionTowards,
      seaLevelMsl: seaLevelWeight > 0 ? weightedSeaLevel / seaLevelWeight : null,
      samples,
      ...aggregateEffect,
    });
  });
  return {
    complete,
    startTime: startDate.toISOString(),
    arrivalTime: new Date(startDate.getTime() + elapsedSeconds * 1000).toISOString(),
    durationSeconds: complete ? elapsedSeconds : null,
    legs,
    driftCoordinates,
  };
}

export function routeCurrentGeoJson(estimate, arrowLength = 0.012) {
  if (!estimate?.legs) return { type: "FeatureCollection", features: [] };
  const features = [];
  if (estimate.driftCoordinates?.length > 1) {
    features.push({
      type: "Feature",
      properties: {
        kind: "drift-line",
        timing: "expected-route",
        warning: "Modelled track if each planned ground-track bearing is held without correcting for current.",
      },
      geometry: { type: "LineString", coordinates: estimate.driftCoordinates },
    });
  }
  estimate.legs.forEach((leg) => {
    leg.samples?.forEach((sample) => {
      if (!Number.isFinite(sample.headingDegrees)) return;
      const properties = {
        kind: "course-to-steer-arrow",
        legIndex: leg.index,
        speedKnots: sample.currentSpeedKnots,
        speedLabel: `CTS ${String(Math.round(sample.headingDegrees)).padStart(3, "0")}°T`,
        directionTowards: sample.currentDirectionTowards,
        validTime: sample.midpointTime,
        timing: "expected-route",
        effectiveSpeedKnots: sample.effectiveSpeedKnots,
        headingDegrees: sample.headingDegrees,
        trackBearingDegrees: leg.bearingDegrees,
        alongKnots: sample.alongKnots,
        crossKnots: sample.crossKnots,
        seaLevelMsl: sample.seaLevelMsl,
      };
      features.push(arrowFeature(sample.point, sample.headingDegrees, arrowLength, properties));
      features.push({
        type: "Feature",
        properties: { ...properties, kind: "course-to-steer-label" },
        geometry: {
          type: "Point",
          coordinates: [sample.point.longitude, sample.point.latitude],
        },
      });
    });
  });
  return { type: "FeatureCollection", features };
}

export function depthAdjustmentFor({ provider, point, seaLevelMsl }) {
  if (!Number.isFinite(seaLevelMsl) || !point) return null;
  if (provider === "gebco") {
    return {
      heightM: seaLevelMsl,
      chartDatum: "MSL",
      sourceName: "Open-Meteo marine model",
      stationName: null,
    };
  }
  if (provider !== "emodnet") return null;
  const station = nearestDatumStation(point, 60);
  if (!station) return null;
  return {
    heightM: station.mslAboveChartDatumM + seaLevelMsl,
    chartDatum: station.chartDatum,
    sourceName: "Open-Meteo + TICON-4 datum transform",
    stationName: station.name,
  };
}

export function currentEffect(
  boatSpeedKnots,
  trackBearingDegrees,
  currentSpeedKnots,
  currentDirectionTowards,
) {
  const boatSpeed = Number(boatSpeedKnots);
  const currentSpeed = Number(currentSpeedKnots);
  if (![boatSpeed, trackBearingDegrees, currentSpeed, currentDirectionTowards].every(Number.isFinite)) {
    return null;
  }
  const delta = ((currentDirectionTowards - trackBearingDegrees) * Math.PI) / 180;
  const alongKnots = currentSpeed * Math.cos(delta);
  const crossKnots = currentSpeed * Math.sin(delta);
  if (boatSpeed <= 0 || Math.abs(crossKnots) >= boatSpeed) return null;
  const boatAlongKnots = Math.sqrt(boatSpeed ** 2 - crossKnots ** 2);
  const effectiveSpeedKnots = boatAlongKnots + alongKnots;
  if (effectiveSpeedKnots <= 0.1) return null;
  const correctionDegrees = (Math.atan2(-crossKnots, boatAlongKnots) * 180) / Math.PI;
  return {
    alongKnots,
    crossKnots,
    effectiveSpeedKnots,
    headingDegrees: normalizeBearing(trackBearingDegrees + correctionDegrees),
  };
}

function marineVector(hourly, index) {
  const speedKnots = Number(hourly?.ocean_current_velocity?.[index]);
  const directionTowards = Number(hourly?.ocean_current_direction?.[index]);
  if (!Number.isFinite(speedKnots) || !Number.isFinite(directionTowards)) return null;
  const radians = (directionTowards * Math.PI) / 180;
  const seaLevel = Number(hourly?.sea_level_height_msl?.[index]);
  return {
    eastKnots: speedKnots * Math.sin(radians),
    northKnots: speedKnots * Math.cos(radians),
    seaLevelMsl: Number.isFinite(seaLevel) ? seaLevel : null,
  };
}

function arrowFeature(point, bearingDegrees, length, properties) {
  const start = offsetPoint(point, normalizeBearing(bearingDegrees + 180), length * 0.48);
  const end = offsetPoint(point, bearingDegrees, length * 0.48);
  const endpoint = { longitude: end[0], latitude: end[1] };
  const left = offsetPoint(endpoint, normalizeBearing(bearingDegrees + 150), length * 0.32);
  const right = offsetPoint(endpoint, normalizeBearing(bearingDegrees + 210), length * 0.32);
  return {
    type: "Feature",
    properties,
    geometry: { type: "MultiLineString", coordinates: [[start, end], [end, left], [end, right]] },
  };
}

function offsetPoint(point, bearingDegrees, latitudeDegrees) {
  const radians = (bearingDegrees * Math.PI) / 180;
  return [
    point.longitude +
      (Math.sin(radians) * latitudeDegrees) /
        Math.max(0.2, Math.cos((point.latitude * Math.PI) / 180)),
    point.latitude + Math.cos(radians) * latitudeDegrees,
  ];
}

function nearestDatumStation(point, maximumKilometres) {
  return SOLENT_TIDE_DATUMS
    .map((station) => ({ station, distance: distanceKilometres(point, station) }))
    .filter((value) => value.distance <= maximumKilometres)
    .sort((first, second) => first.distance - second.distance)[0]?.station ?? null;
}

function distanceKilometres(first, second) {
  const radians = Math.PI / 180;
  const latitude1 = first.latitude * radians;
  const latitude2 = second.latitude * radians;
  const deltaLatitude = (second.latitude - first.latitude) * radians;
  const deltaLongitude = (second.longitude - first.longitude) * radians;
  const value =
    Math.sin(deltaLatitude / 2) ** 2 +
    Math.cos(latitude1) * Math.cos(latitude2) * Math.sin(deltaLongitude / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

function midpointCoordinate(first, second) {
  return {
    latitude: (Number(first.latitude) + Number(second.latitude)) / 2,
    longitude: (Number(first.longitude) + Number(second.longitude)) / 2,
  };
}

function interpolateCoordinate(first, second, fraction) {
  return {
    latitude: Number(first.latitude) + (Number(second.latitude) - Number(first.latitude)) * fraction,
    longitude: Number(first.longitude) +
      (Number(second.longitude) - Number(first.longitude)) * fraction,
  };
}

function nearestPointOnLeg(point, leg) {
  const latitude = (Number(leg.from.latitude) + Number(leg.to.latitude)) / 2;
  const longitudeScale = Math.cos((latitude * Math.PI) / 180);
  const ax = Number(leg.from.longitude) * longitudeScale;
  const ay = Number(leg.from.latitude);
  const bx = Number(leg.to.longitude) * longitudeScale;
  const by = Number(leg.to.latitude);
  const px = Number(point.longitude) * longitudeScale;
  const py = Number(point.latitude);
  const lengthSquared = (bx - ax) ** 2 + (by - ay) ** 2;
  const fraction = lengthSquared > 0
    ? Math.max(0, Math.min(1, ((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / lengthSquared))
    : 0;
  const nearest = interpolateCoordinate(leg.from, leg.to, fraction);
  return { leg, fraction, distanceNm: distanceKilometres(point, nearest) / 1.852 };
}

function displaceByVelocity(
  point,
  boatSpeedKnots,
  boatBearingDegrees,
  currentSpeedKnots,
  currentBearingDegrees,
  durationHours,
) {
  const boatRadians = (boatBearingDegrees * Math.PI) / 180;
  const currentRadians = (currentBearingDegrees * Math.PI) / 180;
  const eastNm =
    (boatSpeedKnots * Math.sin(boatRadians) + currentSpeedKnots * Math.sin(currentRadians)) *
    durationHours;
  const northNm =
    (boatSpeedKnots * Math.cos(boatRadians) + currentSpeedKnots * Math.cos(currentRadians)) *
    durationHours;
  return {
    longitude: Number(point.longitude) + eastNm /
      (60 * Math.max(0.2, Math.cos((Number(point.latitude) * Math.PI) / 180))),
    latitude: Number(point.latitude) + northNm / 60,
  };
}

function interpolateNullable(first, second, fraction) {
  if (Number.isFinite(first) && Number.isFinite(second)) return first + (second - first) * fraction;
  return Number.isFinite(first) ? first : Number.isFinite(second) ? second : null;
}

function formatUtcHour(date) {
  return date.toISOString().slice(0, 13) + ":00";
}

function validDate(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error("Choose a valid passage start time.");
  return date;
}

function normalizeBearing(value) {
  return ((value % 360) + 360) % 360;
}
