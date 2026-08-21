import {
  deriveShallowContours,
  parseEmodnetShadingGrid,
} from "./emodnet-contours.mjs";

export function buildShadingContours({ bounds, colourScale, height, options, pixels, width }) {
  const parsed = parseEmodnetShadingGrid(
    { width, height, data: new Uint8ClampedArray(pixels) },
    colourScale,
    bounds,
  );
  const simplifyTolerance = Math.max(
    Math.abs(parsed.transform.longitudeStep),
    Math.abs(parsed.transform.latitudeStep),
  ) * 0.65;
  return deriveShallowContours(parsed, undefined, {
    ...options,
    simplifyTolerance,
  });
}

if (typeof self !== "undefined") {
  self.addEventListener("message", (event) => {
    try {
      self.postMessage({ contours: buildShadingContours(event.data) });
    } catch (error) {
      self.postMessage({
        error: error instanceof Error ? error.message : "Contour generation failed.",
      });
    }
  });
}
