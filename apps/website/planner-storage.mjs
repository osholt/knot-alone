export const PLANNER_DRAFT_KEY = "tide-and-seek-passage-planner-v1";
export const PLANNER_DRAFT_MAX_AGE = 180 * 24 * 60 * 60 * 1000;

export function encodePlannerDraft(state, savedAt = Date.now()) {
  return JSON.stringify({ version: 1, savedAt, ...state });
}

export function decodePlannerDraft(
  serialized,
  { now = Date.now(), maxAge = PLANNER_DRAFT_MAX_AGE, maxStops = 50 } = {},
) {
  try {
    const draft = JSON.parse(serialized);
    if (
      draft?.version !== 1 ||
      !Number.isFinite(draft.savedAt) ||
      draft.savedAt > now + 60_000 ||
      now - draft.savedAt > maxAge ||
      typeof draft.passageName !== "string" ||
      draft.passageName.length > 100 ||
      !Array.isArray(draft.stops) ||
      draft.stops.length > maxStops
    ) return null;

    const identifiers = new Set();
    const stops = draft.stops.map((stop) => {
      if (
        !Number.isInteger(stop?.id) ||
        identifiers.has(stop.id) ||
        !validCoordinate(stop.longitude, stop.latitude)
      ) throw new Error("Invalid saved waypoint");
      identifiers.add(stop.id);
      return {
        id: stop.id,
        name: String(stop.name || "").slice(0, 100),
        notes: String(stop.notes || "").slice(0, 500),
        longitude: Number(stop.longitude),
        latitude: Number(stop.latitude),
      };
    });
    return {
      savedAt: draft.savedAt,
      passageName: draft.passageName,
      speedKnots: finiteBetween(draft.speedKnots, 0.5, 50) ? Number(draft.speedKnots) : 5,
      startTime: validDateString(draft.startTime) ? new Date(draft.startTime).toISOString() : null,
      stops,
      bathymetrySource: ["emodnet", "gebco", "none"].includes(draft.bathymetrySource)
        ? draft.bathymetrySource
        : "emodnet",
      bathymetryVisible: typeof draft.bathymetryVisible === "boolean"
        ? draft.bathymetryVisible
        : !["gebco", "none"].includes(draft.bathymetrySource),
      gebcoVisible: draft.gebcoVisible === true || draft.bathymetrySource === "gebco",
      depthPalette: ["nautical", "multicolour", "high-contrast"].includes(draft.depthPalette)
        ? draft.depthPalette
        : "nautical",
      shallowContoursVisible: draft.shallowContoursVisible !== false,
      offshoreContoursVisible:
        draft.offshoreContoursVisible === true || draft.contoursVisible === true,
      noaaVisible: draft.noaaVisible === true,
      seamarksVisible: draft.seamarksVisible !== false,
      windVisible: draft.windVisible === true,
      currentVisible: draft.currentVisible !== false,
      poiCategories: Array.isArray(draft.poiCategories)
        ? draft.poiCategories.filter((value) => typeof value === "string").slice(0, 20)
        : [],
    };
  } catch {
    return null;
  }
}

function validCoordinate(longitude, latitude) {
  return finiteBetween(longitude, -180, 180) && finiteBetween(latitude, -90, 90);
}

function finiteBetween(value, minimum, maximum) {
  const number = Number(value);
  return Number.isFinite(number) && number >= minimum && number <= maximum;
}

function validDateString(value) {
  return typeof value === "string" && value.length <= 40 && Number.isFinite(Date.parse(value));
}
