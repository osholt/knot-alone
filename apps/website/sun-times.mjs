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

export function sunChartRows(response, start, arrival = null) {
  const startTime = validDate(start).getTime();
  const arrivalTime = arrival ? validDate(arrival).getTime() : null;
  const daily = response?.daily;
  const offsetSeconds = Number(response?.utc_offset_seconds) || 0;
  const timezone = response?.timezone || "UTC";
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
  return {
    rows,
    timezone,
    timezoneAbbreviation: response?.timezone_abbreviation || "UTC",
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

function validDate(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error("Choose a valid passage time.");
  return date;
}
