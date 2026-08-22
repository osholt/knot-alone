const FORECAST_API_URL = "https://api.open-meteo.com/v1/forecast";

export function sunRequestUrl(point) {
  if (!point) throw new Error("A daylight position is required.");
  const parameters = new URLSearchParams({
    latitude: Number(point.latitude).toFixed(4),
    longitude: Number(point.longitude).toFixed(4),
    daily: "sunrise,sunset",
    timezone: "auto",
    timeformat: "unixtime",
    forecast_days: "16",
  });
  return `${FORECAST_API_URL}?${parameters}`;
}

export function sunChartRows(response, start, arrival = null, point = null) {
  const startTime = validDate(start).getTime();
  const arrivalTime = arrival ? validDate(arrival).getTime() : null;
  const daily = response?.daily;
  const offsetSeconds = Number(response?.utc_offset_seconds) || 0;
  const timezone = response?.timezone || deviceTimezone();
  const starts = Array.isArray(daily?.time) ? daily.time.map(unixMilliseconds) : [];
  const sunrises = Array.isArray(daily?.sunrise)
    ? daily.sunrise.map(unixMilliseconds)
    : [];
  const sunsets = Array.isArray(daily?.sunset)
    ? daily.sunset.map(unixMilliseconds)
    : [];
  const rows = [];
  starts.forEach((dayStart, index) => {
    const dayEnd = starts[index + 1] ?? dayStart + 24 * 60 * 60 * 1000;
    const sunrise = sunrises[index];
    const sunset = sunsets[index];
    if (![dayStart, dayEnd, sunrise, sunset].every(Number.isFinite)) return;
    const hasStart = startTime >= dayStart && startTime < dayEnd;
    const hasArrival = Number.isFinite(arrivalTime) && arrivalTime >= dayStart && arrivalTime < dayEnd;
    if (!hasStart && !hasArrival) return;
    const duration = dayEnd - dayStart;
    rows.push({
      date: localDateLabel(dayStart, timezone, offsetSeconds),
      sunrise: new Date(sunrise).toISOString(),
      sunset: new Date(sunset).toISOString(),
      sunriseLabel: localClockLabel(sunrise, timezone, offsetSeconds),
      sunsetLabel: localClockLabel(sunset, timezone, offsetSeconds),
      daylightStartPercent: percentage(sunrise - dayStart, duration),
      daylightWidthPercent: percentage(sunset - sunrise, duration),
      startPercent: hasStart ? percentage(startTime - dayStart, duration) : null,
      arrivalPercent: hasArrival ? percentage(arrivalTime - dayStart, duration) : null,
      startLabel: hasStart ? localClockLabel(startTime, timezone, offsetSeconds) : null,
      arrivalLabel: hasArrival ? localClockLabel(arrivalTime, timezone, offsetSeconds) : null,
      arrivalAfterSunset: hasArrival && arrivalTime > sunset,
      arrivalBeforeSunrise: hasArrival && arrivalTime < sunrise,
    });
  });
  let locallyCalculated = false;
  if (point && (!rows.some((row) => row.startPercent !== null)
    || (Number.isFinite(arrivalTime) && !rows.some((row) => row.arrivalPercent !== null)))) {
    const calculated = calculatedRows(point, startTime, arrivalTime, timezone, offsetSeconds);
    for (const row of calculated) {
      if (rows.some((existing) => existing.date === row.date)) continue;
      rows.push(row);
      locallyCalculated = true;
    }
    rows.sort((left, right) => left.date.localeCompare(right.date));
  }
  return {
    rows,
    timezone,
    timezoneAbbreviation: response?.timezone_abbreviation
      || timezoneAbbreviation(startTime, timezone, offsetSeconds),
    locallyCalculated,
  };
}

function calculatedRows(point, startTime, arrivalTime, timezone, offsetSeconds) {
  const latitude = Number(point?.latitude);
  const longitude = Number(point?.longitude);
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90
    || !Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
    throw new Error("A valid daylight position is required.");
  }
  const dates = new Set([localDateLabel(startTime, timezone, offsetSeconds)]);
  if (Number.isFinite(arrivalTime)) {
    dates.add(localDateLabel(arrivalTime, timezone, offsetSeconds));
  }
  return [...dates].sort().map((date) => {
    const events = solarEvents(date, latitude, longitude);
    const hasStart = localDateLabel(startTime, timezone, offsetSeconds) === date;
    const hasArrival = Number.isFinite(arrivalTime)
      && localDateLabel(arrivalTime, timezone, offsetSeconds) === date;
    const startPercent = hasStart
      ? localClockPercentage(startTime, timezone, offsetSeconds)
      : null;
    const arrivalPercent = hasArrival
      ? localClockPercentage(arrivalTime, timezone, offsetSeconds)
      : null;
    if (events.state !== "normal") {
      const polarDay = events.state === "polar-day";
      return {
        date,
        sunrise: null,
        sunset: null,
        sunriseLabel: polarDay ? "above horizon" : "below horizon",
        sunsetLabel: "all day",
        daylightStartPercent: 0,
        daylightWidthPercent: polarDay ? 100 : 0,
        startPercent,
        arrivalPercent,
        startLabel: hasStart ? localClockLabel(startTime, timezone, offsetSeconds) : null,
        arrivalLabel: hasArrival ? localClockLabel(arrivalTime, timezone, offsetSeconds) : null,
        arrivalAfterSunset: hasArrival && !polarDay,
        arrivalBeforeSunrise: false,
      };
    }
    const sunrise = events.sunrise.getTime();
    const sunset = events.sunset.getTime();
    const sunrisePercent = localClockPercentage(sunrise, timezone, offsetSeconds);
    const sunsetPercent = localClockPercentage(sunset, timezone, offsetSeconds);
    return {
      date,
      sunrise: events.sunrise.toISOString(),
      sunset: events.sunset.toISOString(),
      sunriseLabel: localClockLabel(sunrise, timezone, offsetSeconds),
      sunsetLabel: localClockLabel(sunset, timezone, offsetSeconds),
      daylightStartPercent: sunrisePercent,
      daylightWidthPercent: Math.max(0, sunsetPercent - sunrisePercent),
      startPercent,
      arrivalPercent,
      startLabel: hasStart ? localClockLabel(startTime, timezone, offsetSeconds) : null,
      arrivalLabel: hasArrival ? localClockLabel(arrivalTime, timezone, offsetSeconds) : null,
      arrivalAfterSunset: hasArrival && arrivalTime > sunset,
      arrivalBeforeSunrise: hasArrival && arrivalTime < sunrise,
    };
  });
}

// NOAA's solar-position equations are deterministic, need no weather forecast,
// and remain useful when the chosen passage date is outside a model window.
function solarEvents(date, latitude, longitude) {
  const midnight = Date.parse(`${date}T00:00:00Z`);
  const julianDayAtNoon = midnight / 86_400_000 + 2_440_587.5 + 0.5;
  const centuries = (julianDayAtNoon - 2_451_545) / 36_525;
  const meanLongitude = normalDegrees(
    280.46646 + centuries * (36_000.76983 + centuries * 0.0003032),
  );
  const meanAnomaly = normalDegrees(
    357.52911 + centuries * (35_999.05029 - 0.0001537 * centuries),
  );
  const eccentricity = 0.016708634
    - centuries * (0.000042037 + 0.0000001267 * centuries);
  const meanObliquity = 23
    + (26 + (21.448 - centuries * (46.815 + centuries * (0.00059 - centuries * 0.001813))) / 60) / 60;
  const omega = 125.04 - 1934.136 * centuries;
  const obliquity = meanObliquity + 0.00256 * cosineDegrees(omega);
  const equationCentre = sineDegrees(meanAnomaly)
      * (1.914602 - centuries * (0.004817 + 0.000014 * centuries))
    + sineDegrees(2 * meanAnomaly) * (0.019993 - 0.000101 * centuries)
    + sineDegrees(3 * meanAnomaly) * 0.000289;
  const apparentLongitude = meanLongitude + equationCentre
    - 0.00569 - 0.00478 * sineDegrees(omega);
  const declination = Math.asin(
    sineDegrees(obliquity) * sineDegrees(apparentLongitude),
  );
  const y = Math.tan(toRadians(obliquity / 2)) ** 2;
  const equationMinutes = 4 * toDegrees(
    y * Math.sin(2 * toRadians(meanLongitude))
      - 2 * eccentricity * Math.sin(toRadians(meanAnomaly))
      + 4 * eccentricity * y * Math.sin(toRadians(meanAnomaly))
        * Math.cos(2 * toRadians(meanLongitude))
      - 0.5 * y ** 2 * Math.sin(4 * toRadians(meanLongitude))
      - 1.25 * eccentricity ** 2 * Math.sin(2 * toRadians(meanAnomaly)),
  );
  const latitudeRadians = toRadians(latitude);
  const hourAngleCosine = (
    cosineDegrees(90.833) / (Math.cos(latitudeRadians) * Math.cos(declination))
  ) - Math.tan(latitudeRadians) * Math.tan(declination);
  if (hourAngleCosine > 1) return { state: "polar-night" };
  if (hourAngleCosine < -1) return { state: "polar-day" };
  const hourAngle = toDegrees(Math.acos(hourAngleCosine));
  const solarNoonMinutes = 720 - 4 * longitude - equationMinutes;
  return {
    state: "normal",
    sunrise: new Date(midnight + (solarNoonMinutes - 4 * hourAngle) * 60_000),
    sunset: new Date(midnight + (solarNoonMinutes + 4 * hourAngle) * 60_000),
  };
}

function percentage(value, total) {
  return Math.max(0, Math.min(100, (value / total) * 100));
}

function unixMilliseconds(value) {
  return value === null || value === undefined ? Number.NaN : Number(value) * 1000;
}

function localClockLabel(timestamp, timezone, offsetSeconds) {
  try {
    return new Intl.DateTimeFormat("en-GB", {
      timeZone: timezone,
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).format(new Date(timestamp));
  } catch {
    return new Date(timestamp + offsetSeconds * 1000).toISOString().slice(11, 16);
  }
}

function localClockPercentage(timestamp, timezone, offsetSeconds) {
  try {
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: timezone,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date(timestamp));
    const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
    return percentage(
      Number(value.hour) * 3600 + Number(value.minute) * 60 + Number(value.second),
      24 * 60 * 60,
    );
  } catch {
    const local = new Date(timestamp + offsetSeconds * 1000);
    return percentage(
      local.getUTCHours() * 3600 + local.getUTCMinutes() * 60 + local.getUTCSeconds(),
      24 * 60 * 60,
    );
  }
}

function localDateLabel(timestamp, timezone, offsetSeconds) {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(new Date(timestamp));
    const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
    return `${value.year}-${value.month}-${value.day}`;
  } catch {
    return new Date(timestamp + offsetSeconds * 1000).toISOString().slice(0, 10);
  }
}

function timezoneAbbreviation(timestamp, timezone, offsetSeconds) {
  try {
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: timezone,
      timeZoneName: "short",
    }).formatToParts(new Date(timestamp));
    return parts.find((part) => part.type === "timeZoneName")?.value || timezone;
  } catch {
    const sign = offsetSeconds < 0 ? "−" : "+";
    const hours = Math.floor(Math.abs(offsetSeconds) / 3600);
    const minutes = Math.floor((Math.abs(offsetSeconds) % 3600) / 60);
    return `UTC${sign}${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
  }
}

function deviceTimezone() {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}

function toRadians(value) {
  return value * Math.PI / 180;
}

function toDegrees(value) {
  return value * 180 / Math.PI;
}

function sineDegrees(value) {
  return Math.sin(toRadians(value));
}

function cosineDegrees(value) {
  return Math.cos(toRadians(value));
}

function normalDegrees(value) {
  return ((value % 360) + 360) % 360;
}

function validDate(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error("Choose a valid passage time.");
  return date;
}
