const memoryCache = new Map();
const inFlightRequests = new Map();
const cooldowns = new Map();
const STORAGE_PREFIX = "tide-and-seek:forecast:";

export class ForecastRateLimitError extends Error {
  constructor(retryAfterSeconds) {
    super(`forecast service rate limited; try again in ${retryAfterSeconds} s`);
    this.name = "ForecastRateLimitError";
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

export async function fetchForecastJson(
  url,
  {
    ttlMs = 10 * 60 * 1000,
    staleIfErrorMs = 60 * 60 * 1000,
    persist = false,
    fetcher = globalThis.fetch,
    storage = defaultSessionStorage(),
    now = Date.now,
  } = {},
) {
  const cacheKey = String(url);
  const cooldownKey = forecastOrigin(cacheKey);
  const currentTime = now();
  const cached = readCache(cacheKey, persist ? storage : null);
  if (cached && currentTime - cached.savedAt <= ttlMs) {
    return { data: cached.data, cacheStatus: "fresh-cache" };
  }

  const cooldownUntil = cooldowns.get(cooldownKey) || 0;
  if (cooldownUntil > currentTime) {
    if (isUsableStale(cached, currentTime, staleIfErrorMs)) {
      return { data: cached.data, cacheStatus: "stale-cache" };
    }
    throw new ForecastRateLimitError(Math.max(1, Math.ceil((cooldownUntil - currentTime) / 1000)));
  }

  if (inFlightRequests.has(cacheKey)) return inFlightRequests.get(cacheKey);

  const request = (async () => {
    try {
      const response = await fetcher(url, { headers: { Accept: "application/json" } });
      if (response.status === 429) {
        const retryAfterSeconds = parseRetryAfter(response.headers?.get?.("Retry-After"), now());
        cooldowns.set(cooldownKey, now() + retryAfterSeconds * 1000);
        if (isUsableStale(cached, now(), staleIfErrorMs)) {
          return { data: cached.data, cacheStatus: "stale-cache" };
        }
        throw new ForecastRateLimitError(retryAfterSeconds);
      }
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      const record = { savedAt: now(), data };
      memoryCache.set(cacheKey, record);
      if (persist && storage) writeStoredCache(storage, cacheKey, record);
      return { data, cacheStatus: "network" };
    } catch (error) {
      if (isUsableStale(cached, now(), staleIfErrorMs)) {
        return { data: cached.data, cacheStatus: "stale-cache" };
      }
      throw error;
    } finally {
      inFlightRequests.delete(cacheKey);
    }
  })();

  inFlightRequests.set(cacheKey, request);
  return request;
}

export function clearForecastCache() {
  memoryCache.clear();
  inFlightRequests.clear();
  cooldowns.clear();
}

function readCache(cacheKey, storage) {
  const memoryRecord = memoryCache.get(cacheKey);
  if (memoryRecord) return memoryRecord;
  if (!storage) return null;
  try {
    const record = JSON.parse(storage.getItem(`${STORAGE_PREFIX}${cacheKey}`));
    if (!Number.isFinite(record?.savedAt) || !("data" in record)) return null;
    memoryCache.set(cacheKey, record);
    return record;
  } catch {
    return null;
  }
}

function writeStoredCache(storage, cacheKey, record) {
  try {
    storage.setItem(`${STORAGE_PREFIX}${cacheKey}`, JSON.stringify(record));
  } catch {
    // The in-memory cache still protects the current planner session.
  }
}

function isUsableStale(record, currentTime, staleIfErrorMs) {
  return Boolean(record && currentTime - record.savedAt <= staleIfErrorMs);
}

function parseRetryAfter(value, currentTime) {
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds > 0) return Math.ceil(seconds);
  const retryDate = Date.parse(value || "");
  if (Number.isFinite(retryDate) && retryDate > currentTime) {
    return Math.ceil((retryDate - currentTime) / 1000);
  }
  return 60;
}

function forecastOrigin(url) {
  try {
    return new URL(url).origin;
  } catch {
    return url;
  }
}

function defaultSessionStorage() {
  try {
    return globalThis.sessionStorage || null;
  } catch {
    return null;
  }
}
