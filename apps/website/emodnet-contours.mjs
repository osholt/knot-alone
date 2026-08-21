export const EMODNET_COVERAGE = Object.freeze({
  west: -70.5,
  south: 11,
  east: 43,
  north: 90,
});
export const SHALLOW_CONTOUR_LEVELS = Object.freeze([2, 5, 10, 20, 30]);

const WCS_URL = "https://ows.emodnet-bathymetry.eu/wcs";
const WMS_URL = "https://ows.emodnet-bathymetry.eu/wms";
const GEBCO_DAP_URL =
  "https://dap.ceda.ac.uk/thredds/dodsC/bodc/gebco/global/gebco_2026/ice_surface_elevation/netcdf/GEBCO_2026.nc";
const NATIVE_STEP_DEGREES = 1 / 960;
const GEBCO_CELLS_PER_DEGREE = 240;
const MAX_GRID_WIDTH = 512;
const MAX_GRID_HEIGHT = 384;
const MAX_SHADING_WIDTH = 1280;
const MAX_SHADING_HEIGHT = 960;
const NUMBER_PATTERN = /[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?/g;

function paddedEmodnetBounds(bounds) {
  const width = bounds.east - bounds.west;
  const height = bounds.north - bounds.south;
  const longitudePadding = Math.max(width * 0.16, NATIVE_STEP_DEGREES * 6);
  const latitudePadding = Math.max(height * 0.16, NATIVE_STEP_DEGREES * 6);
  const requested = {
    west: Math.max(EMODNET_COVERAGE.west, bounds.west - longitudePadding),
    south: Math.max(EMODNET_COVERAGE.south, bounds.south - latitudePadding),
    east: Math.min(EMODNET_COVERAGE.east, bounds.east + longitudePadding),
    north: Math.min(EMODNET_COVERAGE.north, bounds.north + latitudePadding),
  };
  return requested.east > requested.west && requested.north > requested.south
    ? requested
    : null;
}

export function createContourRequest(bounds, zoom) {
  if (!bounds || zoom < 8 || bounds.east <= bounds.west) return null;
  const requested = paddedEmodnetBounds(bounds);
  if (!requested) return null;

  const nativeWidth = Math.max(2, Math.ceil((requested.east - requested.west) / NATIVE_STEP_DEGREES));
  const nativeHeight = Math.max(2, Math.ceil((requested.north - requested.south) / NATIVE_STEP_DEGREES));
  const scale = Math.min(1, MAX_GRID_WIDTH / nativeWidth, MAX_GRID_HEIGHT / nativeHeight);
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

export function createShadingContourRequest(bounds, zoom, viewport = {}) {
  if (!bounds || zoom < 8 || bounds.east <= bounds.west) return null;
  const requested = paddedEmodnetBounds(bounds);
  if (!requested) return null;

  const viewportWidth = Math.max(256, Number(viewport.width) || 768);
  const viewportHeight = Math.max(192, Number(viewport.height) || 576);
  const quality = contourQualityForZoom(zoom);
  const nativeWidth = Math.max(
    2,
    Math.ceil((requested.east - requested.west) / NATIVE_STEP_DEGREES),
  );
  const nativeHeight = Math.max(
    2,
    Math.ceil((requested.north - requested.south) / NATIVE_STEP_DEGREES),
  );
  const width = Math.min(
    MAX_SHADING_WIDTH,
    nativeWidth,
    Math.max(2, Math.round(viewportWidth * quality.rasterScale)),
  );
  const height = Math.min(
    MAX_SHADING_HEIGHT,
    nativeHeight,
    Math.max(2, Math.round(viewportHeight * quality.rasterScale)),
  );
  const parameters = new URLSearchParams({
    service: "WMS",
    version: "1.1.1",
    request: "GetMap",
    layers: "emodnet:mean",
    styles: "multicolour",
    format: "image/png",
    transparent: "true",
    srs: "EPSG:4326",
    bbox: [requested.west, requested.south, requested.east, requested.north]
      .map((value) => value.toFixed(6))
      .join(","),
    width: String(width),
    height: String(height),
  });
  const legendParameters = new URLSearchParams({
    service: "WMS",
    version: "1.1.1",
    request: "GetLegendGraphic",
    layer: "emodnet:mean",
    style: "multicolour",
    format: "application/json",
  });
  return {
    bounds: requested,
    gridWidth: width,
    gridHeight: height,
    nativeResolution: width === nativeWidth && height === nativeHeight,
    simplifyToleranceCells: quality.simplifyToleranceCells,
    smoothPasses: quality.smoothPasses,
    legendUrl: `${WMS_URL}?${legendParameters}`,
    url: `${WMS_URL}?${parameters}`,
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
  const stride = Math.max(
    1,
    Math.ceil(longitudeCount / MAX_GRID_WIDTH),
    Math.ceil(latitudeCount / MAX_GRID_HEIGHT),
  );
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

export function contourSampleSupportsZoom(sampleZoom, visibleZoom) {
  return Boolean(
    Number.isFinite(sampleZoom) &&
      Number.isFinite(visibleZoom) &&
      (visibleZoom <= sampleZoom ||
        contourQualityForZoom(visibleZoom).level === contourQualityForZoom(sampleZoom).level),
  );
}

export function contourQualityForZoom(zoom) {
  const value = Number(zoom);
  if (value >= 15) {
    return { level: 3, rasterScale: 1.3, simplifyToleranceCells: 0.18, smoothPasses: 3 };
  }
  if (value >= 13) {
    return { level: 2, rasterScale: 1.12, simplifyToleranceCells: 0.3, smoothPasses: 2 };
  }
  if (value >= 11) {
    return { level: 1, rasterScale: 0.92, simplifyToleranceCells: 0.45, smoothPasses: 1 };
  }
  return { level: 0, rasterScale: 0.68, simplifyToleranceCells: 0.65, smoothPasses: 0 };
}

export function parseEmodnetGrid(text) {
  const range = text.match(
    /Grid range: GridEnvelope2D\[(-?\d+)\.\.(-?\d+), (-?\d+)\.\.(-?\d+)\]/,
  );
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
  const columnStart = Number(range[1]);
  const columnEnd = Number(range[2]);
  const rowStart = Number(range[3]);
  const rowEnd = Number(range[4]);
  const width = columnEnd - columnStart + 1;
  const height = rowEnd - rowStart + 1;
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
      longitudeOrigin: transform["0_2"] + columnStart * transform["0_0"],
      latitudeStep: transform["1_1"],
      latitudeOrigin: transform["1_2"] + rowStart * transform["1_1"],
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

function parseHexColour(value) {
  const match = String(value || "").match(/^#([0-9a-f]{6})$/i);
  if (!match) return null;
  const colour = Number.parseInt(match[1], 16);
  return [(colour >> 16) & 255, (colour >> 8) & 255, colour & 255];
}

export function parseEmodnetColourScale(payload) {
  const document = typeof payload === "string" ? JSON.parse(payload) : payload;
  const entries = document?.Legend
    ?.flatMap((legend) => legend.rules || [])
    .flatMap((rule) => rule.symbolizers || [])
    .map((symbolizer) => symbolizer.Raster?.colormap?.entries)
    .find(Array.isArray);
  if (!entries) throw new Error("The depth shading service returned no colour scale.");

  const scale = entries
    .map((entry) => ({ elevation: Number(entry.quantity), colour: parseHexColour(entry.color) }))
    .filter((entry) => Number.isFinite(entry.elevation) && entry.colour)
    .sort((first, second) => first.elevation - second.elevation);
  if (scale.length < 2) throw new Error("The depth shading colour scale was incomplete.");
  return scale;
}

function elevationFromColour(colour, scale) {
  let closest = { distanceSquared: Number.POSITIVE_INFINITY, elevation: 0 };
  for (let index = 1; index < scale.length; index += 1) {
    const first = scale[index - 1];
    const second = scale[index];
    const vector = second.colour.map((value, channel) => value - first.colour[channel]);
    const lengthSquared = vector.reduce((sum, value) => sum + value * value, 0);
    const offset = colour.map((value, channel) => value - first.colour[channel]);
    const ratio = lengthSquared === 0
      ? 0
      : Math.max(0, Math.min(1,
        offset.reduce((sum, value, channel) => sum + value * vector[channel], 0) /
          lengthSquared));
    const distanceSquared = colour.reduce((sum, value, channel) => {
      const rendered = first.colour[channel] + vector[channel] * ratio;
      return sum + (value - rendered) ** 2;
    }, 0);
    if (distanceSquared < closest.distanceSquared) {
      closest = {
        distanceSquared,
        elevation: first.elevation + (second.elevation - first.elevation) * ratio,
      };
    }
  }
  return closest.elevation;
}

export function parseEmodnetShadingGrid(imageData, colourScale, bounds) {
  const sourceWidth = Number(imageData?.width);
  const sourceHeight = Number(imageData?.height);
  const pixels = imageData?.data;
  if (
    !Number.isInteger(sourceWidth) ||
    !Number.isInteger(sourceHeight) ||
    sourceWidth < 2 ||
    sourceHeight < 2 ||
    pixels?.length !== sourceWidth * sourceHeight * 4 ||
    !bounds ||
    bounds.east <= bounds.west ||
    bounds.north <= bounds.south ||
    !Array.isArray(colourScale) ||
    colourScale.length < 2
  ) {
    throw new Error("The depth shading image was incomplete.");
  }

  // GeoServer expands the roughly 1/960° EMODnet cells with nearest-neighbour
  // pixels when the requested image is larger than the source grid. Trace one
  // sample per real model cell so marching squares interpolates between depth
  // samples instead of following the edges of those repeated display pixels.
  const width = Math.min(
    sourceWidth,
    Math.max(2, Math.ceil((bounds.east - bounds.west) / NATIVE_STEP_DEGREES)),
  );
  const height = Math.min(
    sourceHeight,
    Math.max(2, Math.ceil((bounds.north - bounds.south) / NATIVE_STEP_DEGREES)),
  );
  const colourCache = new Map();
  const rows = Array.from({ length: height }, () => Array(width));
  for (let row = 0; row < height; row += 1) {
    const sourceRow = Math.min(
      sourceHeight - 1,
      Math.floor(((row + 0.5) / height) * sourceHeight),
    );
    for (let column = 0; column < width; column += 1) {
      const sourceColumn = Math.min(
        sourceWidth - 1,
        Math.floor(((column + 0.5) / width) * sourceWidth),
      );
      const offset = (sourceRow * sourceWidth + sourceColumn) * 4;
      if (pixels[offset + 3] < 128) {
        rows[row][column] = Number.NaN;
        continue;
      }
      const key = (pixels[offset] << 16) | (pixels[offset + 1] << 8) | pixels[offset + 2];
      if (!colourCache.has(key)) {
        colourCache.set(
          key,
          elevationFromColour(
            [pixels[offset], pixels[offset + 1], pixels[offset + 2]],
            colourScale,
          ),
        );
      }
      rows[row][column] = colourCache.get(key);
    }
  }

  const longitudeStep = (bounds.east - bounds.west) / width;
  const latitudeStep = -(bounds.north - bounds.south) / height;
  return {
    rows,
    transform: {
      longitudeStep,
      longitudeOrigin: bounds.west + longitudeStep / 2,
      latitudeStep,
      latitudeOrigin: bounds.north + latitudeStep / 2,
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

function contourSegments(grid, level) {
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
      const corners = [
        grid[row][column],
        grid[row][column + 1],
        grid[row + 1][column + 1],
        grid[row + 1][column],
      ];
      if (corners.some((corner) => !Number.isFinite(corner))) continue;
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

function squaredDistanceToSegment(point, first, second) {
  const longitudeDelta = second[0] - first[0];
  const latitudeDelta = second[1] - first[1];
  const lengthSquared = longitudeDelta ** 2 + latitudeDelta ** 2;
  if (lengthSquared === 0) {
    return (point[0] - first[0]) ** 2 + (point[1] - first[1]) ** 2;
  }
  const ratio = Math.max(0, Math.min(1,
    ((point[0] - first[0]) * longitudeDelta + (point[1] - first[1]) * latitudeDelta) /
      lengthSquared));
  const projected = [
    first[0] + ratio * longitudeDelta,
    first[1] + ratio * latitudeDelta,
  ];
  return (point[0] - projected[0]) ** 2 + (point[1] - projected[1]) ** 2;
}

function simplifyLine(coordinates, tolerance) {
  if (coordinates.length <= 2 || !Number.isFinite(tolerance) || tolerance <= 0) {
    return coordinates;
  }
  const keep = new Uint8Array(coordinates.length);
  keep[0] = 1;
  keep[coordinates.length - 1] = 1;
  const toleranceSquared = tolerance ** 2;
  const ranges = [[0, coordinates.length - 1]];
  while (ranges.length) {
    const [firstIndex, lastIndex] = ranges.pop();
    let furthestIndex = -1;
    let furthestDistance = toleranceSquared;
    for (let index = firstIndex + 1; index < lastIndex; index += 1) {
      const distance = squaredDistanceToSegment(
        coordinates[index],
        coordinates[firstIndex],
        coordinates[lastIndex],
      );
      if (distance > furthestDistance) {
        furthestDistance = distance;
        furthestIndex = index;
      }
    }
    if (furthestIndex < 0) continue;
    keep[furthestIndex] = 1;
    ranges.push([firstIndex, furthestIndex], [furthestIndex, lastIndex]);
  }
  return coordinates.filter((_, index) => keep[index]);
}

function smoothLine(points, passes) {
  let result = points;
  const passCount = Math.max(0, Math.min(4, Math.floor(Number(passes) || 0)));
  for (let pass = 0; pass < passCount && result.length > 3; pass += 1) {
    const closed = pointKey(result[0]) === pointKey(result.at(-1));
    const uniqueLength = closed ? result.length - 1 : result.length;
    const next = result.map((point) => [...point]);
    const start = closed ? 0 : 1;
    const end = closed ? uniqueLength : uniqueLength - 1;
    for (let index = start; index < end; index += 1) {
      const previous = result[(index - 1 + uniqueLength) % uniqueLength];
      const current = result[index];
      const following = result[(index + 1) % uniqueLength];
      next[index] = [
        previous[0] * 0.25 + current[0] * 0.5 + following[0] * 0.25,
        previous[1] * 0.25 + current[1] * 0.5 + following[1] * 0.25,
      ];
    }
    if (closed) next[next.length - 1] = [...next[0]];
    result = next;
  }
  return result;
}

export function deriveShallowContours(
  parsed,
  levels = SHALLOW_CONTOUR_LEVELS,
  {
    featurePrefix = "emodnet-live",
    simplifyTolerance = 0,
    smoothPasses = 0,
    sourceName = "EMODnet Bathymetry DTM 2024",
    warning = "Model-derived contour; not a charted sounding or safe clearance.",
  } = {},
) {
  const depthGrid = parsed.rows.map((row) => row.map((elevation) => -elevation));
  const features = [];
  for (const level of levels) {
    const lines = stitchSegments(contourSegments(depthGrid, level));
    lines.forEach((line, index) => {
      if (line.length < 3) return;
      const coordinates = simplifyLine(smoothLine(line, smoothPasses).map(([row, column]) => [
        Number((parsed.transform.longitudeOrigin + column * parsed.transform.longitudeStep).toFixed(6)),
        Number((parsed.transform.latitudeOrigin + row * parsed.transform.latitudeStep).toFixed(6)),
      ]), simplifyTolerance);
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

function coordinateInsideBounds([longitude, latitude], bounds) {
  return Boolean(
    bounds &&
      longitude >= bounds.west &&
      longitude <= bounds.east &&
      latitude >= bounds.south &&
      latitude <= bounds.north,
  );
}

function sameCoordinate(first, second) {
  return first[0] === second[0] && first[1] === second[1];
}

function pointOnSegment([longitude, latitude], first, second) {
  const cross = (latitude - first[1]) * (second[0] - first[0]) -
    (longitude - first[0]) * (second[1] - first[1]);
  if (Math.abs(cross) > 1e-10) return false;
  return longitude >= Math.min(first[0], second[0]) &&
    longitude <= Math.max(first[0], second[0]) &&
    latitude >= Math.min(first[1], second[1]) &&
    latitude <= Math.max(first[1], second[1]);
}

function ringContainsCoordinate(ring, coordinate) {
  let inside = false;
  for (let index = 0, previous = ring.length - 1; index < ring.length; previous = index++) {
    const first = ring[previous];
    const second = ring[index];
    if (pointOnSegment(coordinate, first, second)) return true;
    const crossesLatitude = (first[1] > coordinate[1]) !== (second[1] > coordinate[1]);
    if (
      crossesLatitude &&
      coordinate[0] <
        ((second[0] - first[0]) * (coordinate[1] - first[1])) /
          (second[1] - first[1]) + first[0]
    ) {
      inside = !inside;
    }
  }
  return inside;
}

function polygonContainsCoordinate(rings, coordinate) {
  return Boolean(
    rings?.length &&
      ringContainsCoordinate(rings[0], coordinate) &&
      !rings.slice(1).some((ring) => ringContainsCoordinate(ring, coordinate)),
  );
}

export function geometryContainsCoordinate(geometry, coordinate) {
  if (geometry?.type === "Polygon") {
    return polygonContainsCoordinate(geometry.coordinates, coordinate);
  }
  if (geometry?.type === "MultiPolygon") {
    return geometry.coordinates.some((polygon) =>
      polygonContainsCoordinate(polygon, coordinate));
  }
  return false;
}

export function clipContoursToWater(contours, isWater, bounds = null) {
  if (!contours || typeof isWater !== "function") return contours;
  const waterAt = (coordinate) =>
    !bounds || !coordinateInsideBounds(coordinate, bounds) || isWater(coordinate);
  const features = [];

  for (const feature of contours.features || []) {
    if (feature.geometry?.type !== "LineString") {
      features.push(feature);
      continue;
    }
    const coordinates = feature.geometry.coordinates;
    const parts = [];
    let part = [];
    const flush = () => {
      if (part.length >= 2) parts.push(part);
      part = [];
    };
    for (let index = 1; index < coordinates.length; index += 1) {
      const first = coordinates[index - 1];
      const second = coordinates[index];
      const midpoint = [(first[0] + second[0]) / 2, (first[1] + second[1]) / 2];
      if (waterAt(first) && waterAt(midpoint) && waterAt(second)) {
        if (!part.length) part.push(first);
        if (!sameCoordinate(part.at(-1), second)) part.push(second);
      } else {
        flush();
      }
    }
    flush();
    parts.forEach((coordinatesPart, index) => {
      features.push({
        ...feature,
        id: `${feature.id || "contour"}-water-${index}`,
        geometry: { ...feature.geometry, coordinates: coordinatesPart },
      });
    });
  }
  return { ...contours, features };
}
