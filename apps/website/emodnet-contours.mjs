export const EMODNET_COVERAGE = Object.freeze({
  west: -70.5,
  south: 11,
  east: 43,
  north: 90,
});
export const SHALLOW_CONTOUR_LEVELS = Object.freeze([2, 5, 10, 20, 30]);

const WCS_URL = "https://ows.emodnet-bathymetry.eu/wcs";
const GEBCO_DAP_URL =
  "https://dap.ceda.ac.uk/thredds/dodsC/bodc/gebco/global/gebco_2026/ice_surface_elevation/netcdf/GEBCO_2026.nc";
const NATIVE_STEP_DEGREES = 1 / 960;
const GEBCO_CELLS_PER_DEGREE = 240;
const NUMBER_PATTERN = /[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?/g;

export function createContourRequest(bounds, zoom) {
  if (!bounds || zoom < 8 || bounds.east <= bounds.west) return null;
  const width = bounds.east - bounds.west;
  const height = bounds.north - bounds.south;
  const requested = {
    west: Math.max(EMODNET_COVERAGE.west, bounds.west - width * 0.16),
    south: Math.max(EMODNET_COVERAGE.south, bounds.south - height * 0.16),
    east: Math.min(EMODNET_COVERAGE.east, bounds.east + width * 0.16),
    north: Math.min(EMODNET_COVERAGE.north, bounds.north + height * 0.16),
  };
  if (requested.east <= requested.west || requested.north <= requested.south) return null;

  const nativeWidth = Math.max(2, Math.ceil((requested.east - requested.west) / NATIVE_STEP_DEGREES));
  const nativeHeight = Math.max(2, Math.ceil((requested.north - requested.south) / NATIVE_STEP_DEGREES));
  const scale = Math.min(1, 320 / nativeWidth, 240 / nativeHeight);
  const gridWidth = Math.max(2, Math.floor(nativeWidth * scale));
  const gridHeight = Math.max(2, Math.floor(nativeHeight * scale));
  const parameters = new URLSearchParams({
    service: "WCS",
    version: "2.0.1",
    request: "GetCoverage",
    coverageId: "emodnet__mean",
    format: "text/plain",
  });
  parameters.append("subset", `Long(${requested.west.toFixed(6)},${requested.east.toFixed(6)})`);
  parameters.append("subset", `Lat(${requested.south.toFixed(6)},${requested.north.toFixed(6)})`);
  if (scale < 0.999) parameters.set("scaleSize", `i(${gridWidth}),j(${gridHeight})`);
  return {
    bounds: requested,
    gridWidth,
    gridHeight,
    resolutionLimited: scale < 0.999,
    url: `${WCS_URL}?${parameters}`,
  };
}

export function createGebcoContourRequest(bounds, zoom) {
  if (
    !bounds ||
    zoom < 8 ||
    bounds.east <= bounds.west ||
    bounds.west < -180 ||
    bounds.east > 180
  ) {
    return null;
  }
  const width = bounds.east - bounds.west;
  const height = bounds.north - bounds.south;
  const requested = {
    west: Math.max(-180, bounds.west - width * 0.16),
    south: Math.max(-89.997916, bounds.south - height * 0.16),
    east: Math.min(179.997916, bounds.east + width * 0.16),
    north: Math.min(89.997916, bounds.north + height * 0.16),
  };
  if (requested.east <= requested.west || requested.north <= requested.south) return null;

  const longitudeStart = Math.max(
    0,
    Math.floor((requested.west + 180) * GEBCO_CELLS_PER_DEGREE),
  );
  const longitudeEnd = Math.min(
    86_399,
    Math.ceil((requested.east + 180) * GEBCO_CELLS_PER_DEGREE) - 1,
  );
  const latitudeStart = Math.max(
    0,
    Math.floor((requested.south + 90) * GEBCO_CELLS_PER_DEGREE),
  );
  const latitudeEnd = Math.min(
    43_199,
    Math.ceil((requested.north + 90) * GEBCO_CELLS_PER_DEGREE) - 1,
  );
  const longitudeCount = longitudeEnd - longitudeStart + 1;
  const latitudeCount = latitudeEnd - latitudeStart + 1;
  const stride = Math.max(1, Math.ceil(longitudeCount / 320), Math.ceil(latitudeCount / 240));
  const longitudeSamples = Math.floor((longitudeEnd - longitudeStart) / stride) + 1;
  const latitudeSamples = Math.floor((latitudeEnd - latitudeStart) / stride) + 1;
  const query =
    `elevation[${latitudeStart}:${stride}:${latitudeEnd}]` +
    `[${longitudeStart}:${stride}:${longitudeEnd}]`;
  return {
    bounds: requested,
    gridWidth: longitudeSamples,
    gridHeight: latitudeSamples,
    resolutionLimited: stride > 1,
    url: `${GEBCO_DAP_URL}.ascii?${query}`,
  };
}

export function boundsContain(outer, inner) {
  return Boolean(
    outer &&
      inner &&
      outer.west <= inner.west &&
      outer.south <= inner.south &&
      outer.east >= inner.east &&
      outer.north >= inner.north,
  );
}

export function parseEmodnetGrid(text) {
  const range = text.match(/Grid range: GridEnvelope2D\[0\.\.(\d+), 0\.\.(\d+)\]/);
  const transform = Object.fromEntries(
    [...text.matchAll(/PARAMETER\["elt_(0_0|0_2|1_1|1_2)",\s*([-+0-9.eE]+)\]/g)].map(
      (match) => [match[1], Number(match[2])],
    ),
  );
  const marker = "Band 0:";
  const markerIndex = text.indexOf(marker);
  if (!range || Object.keys(transform).length !== 4 || markerIndex < 0) {
    throw new Error("The depth service returned an unrecognised grid.");
  }
  const width = Number(range[1]) + 1;
  const height = Number(range[2]) + 1;
  const values = (text.slice(markerIndex + marker.length).match(NUMBER_PATTERN) || []).map(Number);
  if (values.length !== width * height || values.some((value) => !Number.isFinite(value))) {
    throw new Error("The depth service returned an incomplete grid.");
  }
  const rows = Array.from({ length: height }, (_, row) =>
    values.slice(row * width, (row + 1) * width),
  );
  return {
    rows,
    transform: {
      longitudeStep: transform["0_0"],
      longitudeOrigin: transform["0_2"],
      latitudeStep: transform["1_1"],
      latitudeOrigin: transform["1_2"],
    },
  };
}

export function parseGebcoGrid(text) {
  const gridHeader = text.match(/elevation\.elevation\[(\d+)\]\[(\d+)\]\s*\n/);
  const latitudeHeader = text.match(/\nelevation\.lat\[(\d+)\]\s*\n/);
  const longitudeHeader = text.match(/\nelevation\.lon\[(\d+)\]\s*\n/);
  if (!gridHeader || !latitudeHeader || !longitudeHeader) {
    throw new Error("The global depth service returned an unrecognised grid.");
  }

  const height = Number(gridHeader[1]);
  const width = Number(gridHeader[2]);
  const gridStart = gridHeader.index + gridHeader[0].length;
  const rowText = text.slice(gridStart, latitudeHeader.index);
  const rows = [...rowText.matchAll(/^\[\d+\],\s*(.+)$/gm)].map((match) =>
    (match[1].match(NUMBER_PATTERN) || []).map(Number),
  );
  const latitudeStart = latitudeHeader.index + latitudeHeader[0].length;
  const longitudesStart = longitudeHeader.index + longitudeHeader[0].length;
  const latitudes = (text.slice(latitudeStart, longitudeHeader.index).match(NUMBER_PATTERN) || []).map(
    Number,
  );
  const longitudes = (text.slice(longitudesStart).match(NUMBER_PATTERN) || []).map(Number);
  if (
    rows.length !== height ||
    rows.some((row) => row.length !== width || row.some((value) => !Number.isFinite(value))) ||
    latitudes.length !== height ||
    longitudes.length !== width ||
    [...latitudes, ...longitudes].some((value) => !Number.isFinite(value))
  ) {
    throw new Error("The global depth service returned an incomplete grid.");
  }
  return {
    rows,
    transform: {
      longitudeOrigin: longitudes[0],
      longitudeStep: width > 1 ? longitudes[1] - longitudes[0] : 0,
      latitudeOrigin: latitudes[0],
      latitudeStep: height > 1 ? latitudes[1] - latitudes[0] : 0,
    },
  };
}

function interpolate(first, second, level) {
  if (first === second) return 0.5;
  return Math.max(0, Math.min(1, (level - first) / (second - first)));
}

function edgePoint(row, column, edge, corners, level) {
  const [topLeft, topRight, bottomRight, bottomLeft] = corners;
  if (edge === 0) return [row, column + interpolate(topLeft, topRight, level)];
  if (edge === 1) return [row + interpolate(topRight, bottomRight, level), column + 1];
  if (edge === 2) return [row + 1, column + interpolate(bottomLeft, bottomRight, level)];
  return [row + interpolate(topLeft, bottomLeft, level), column];
}

function contourSegments(grid, level, wetGrid = null) {
  const cases = {
    1: [[3, 0]],
    2: [[0, 1]],
    3: [[3, 1]],
    4: [[1, 2]],
    6: [[0, 2]],
    7: [[3, 2]],
    8: [[2, 3]],
    9: [[0, 2]],
    11: [[1, 2]],
    12: [[1, 3]],
    13: [[0, 1]],
    14: [[3, 0]],
  };
  const segments = [];
  for (let row = 0; row < grid.length - 1; row += 1) {
    for (let column = 0; column < grid[0].length - 1; column += 1) {
      if (wetGrid && ![
        wetGrid[row][column],
        wetGrid[row][column + 1],
        wetGrid[row + 1][column + 1],
        wetGrid[row + 1][column],
      ].every(Boolean)) {
        continue;
      }
      const corners = [
        grid[row][column],
        grid[row][column + 1],
        grid[row + 1][column + 1],
        grid[row + 1][column],
      ];
      const contourCase = corners.reduce(
        (value, corner, index) => value + (corner >= level ? 1 << index : 0),
        0,
      );
      if (contourCase === 0 || contourCase === 15) continue;
      let pairs = cases[contourCase];
      const centreIsDeep = corners.reduce((sum, value) => sum + value, 0) / 4 >= level;
      if (contourCase === 5) {
        pairs = centreIsDeep ? [[0, 1], [2, 3]] : [[3, 0], [1, 2]];
      } else if (contourCase === 10) {
        pairs = centreIsDeep ? [[3, 0], [1, 2]] : [[0, 1], [2, 3]];
      }
      for (const [first, second] of pairs) {
        segments.push([
          edgePoint(row, column, first, corners, level),
          edgePoint(row, column, second, corners, level),
        ]);
      }
    }
  }
  return segments;
}

function pointKey(point) {
  return `${Math.round(point[0] * 1_000_000)}:${Math.round(point[1] * 1_000_000)}`;
}

function stitchSegments(segments) {
  const points = new Map();
  const adjacency = new Map();
  const addEdge = (key, edge) => adjacency.set(key, [...(adjacency.get(key) || []), edge]);
  segments.forEach(([first, second], index) => {
    const firstKey = pointKey(first);
    const secondKey = pointKey(second);
    points.set(firstKey, first);
    points.set(secondKey, second);
    addEdge(firstKey, [index, secondKey]);
    addEdge(secondKey, [index, firstKey]);
  });

  const used = new Set();
  const follow = (start) => {
    const line = [points.get(start)];
    let current = start;
    while (true) {
      const next = (adjacency.get(current) || []).find(([index]) => !used.has(index));
      if (!next) return line;
      used.add(next[0]);
      current = next[1];
      line.push(points.get(current));
      if (current === start) return line;
    }
  };
  const lines = [];
  for (const [key, edges] of adjacency) {
    if (edges.length !== 2) {
      while (edges.some(([index]) => !used.has(index))) lines.push(follow(key));
    }
  }
  segments.forEach(([first], index) => {
    if (!used.has(index)) lines.push(follow(pointKey(first)));
  });
  return lines;
}

function lineLength(coordinates) {
  return coordinates.slice(1).reduce((total, point, index) => {
    const previous = coordinates[index];
    return total + Math.hypot(point[0] - previous[0], point[1] - previous[1]);
  }, 0);
}

export function deriveShallowContours(
  parsed,
  levels = SHALLOW_CONTOUR_LEVELS,
  {
    featurePrefix = "emodnet-live",
    sourceName = "EMODnet Bathymetry DTM 2024",
    warning = "Model-derived contour; not a charted sounding or safe clearance.",
  } = {},
) {
  const depthGrid = parsed.rows.map((row) => row.map((elevation) => -elevation));
  const wetGrid = parsed.rows.map((row) => row.map((elevation) => elevation < 0));
  const features = [];
  for (const level of levels) {
    const lines = stitchSegments(contourSegments(depthGrid, level, wetGrid));
    lines.forEach((line, index) => {
      if (line.length < 3) return;
      const coordinates = line.map(([row, column]) => [
        Number((parsed.transform.longitudeOrigin + column * parsed.transform.longitudeStep).toFixed(6)),
        Number((parsed.transform.latitudeOrigin + row * parsed.transform.latitudeStep).toFixed(6)),
      ]);
      if (lineLength(coordinates) < Math.abs(parsed.transform.longitudeStep) * 1.5) return;
      features.push({
        type: "Feature",
        id: `${featurePrefix}-${level}m-${index}`,
        properties: {
          depthM: level,
          label: `${level} m`,
          derived: true,
          sourceName,
          warning,
        },
        geometry: { type: "LineString", coordinates },
      });
    });
  }
  return { type: "FeatureCollection", features };
}
