import {
  clipContoursToWater,
  deriveShallowContours,
  geometryContainsCoordinate,
  parseEmodnetShadingGrid,
  parseGebcoGrid,
} from "./emodnet-contours.mjs";

let storedContours = null;
let storedSampleId = null;

export function buildShadingContours({ bounds, colourScale, height, options = {}, pixels, width }) {
  const parsed = parseEmodnetShadingGrid(
    { width, height, data: new Uint8ClampedArray(pixels) },
    colourScale,
    bounds,
  );
  const {
    simplifyToleranceCells = 0.65,
    ...deriveOptions
  } = options;
  const simplifyTolerance = Math.max(
    Math.abs(parsed.transform.longitudeStep),
    Math.abs(parsed.transform.latitudeStep),
  ) * simplifyToleranceCells;
  return deriveShallowContours(parsed, undefined, {
    ...deriveOptions,
    simplifyTolerance,
  });
}

export function renderContoursForDisplay(
  contours,
  { adjustment = null, bounds = null, waterGeometries = [] } = {},
) {
  const clipped = waterGeometries.length
    ? clipContoursToWater(
        contours,
        (coordinate) => waterGeometries.some((geometry) =>
          geometryContainsCoordinate(geometry, coordinate)),
        bounds,
      )
    : contours;
  if (!adjustment || !Number.isFinite(Number(adjustment.heightM))) return clipped;
  const tideHeight = Number(adjustment.heightM);
  return {
    ...clipped,
    features: clipped.features.map((feature) => {
      const depth = Number(feature.properties?.depthM);
      const adjustedDepth = depth + tideHeight;
      return {
        ...feature,
        properties: {
          ...feature.properties,
          adjustedDepthM: adjustedDepth,
          displayLabel: `${depth} m ${adjustment.chartDatum} → ~${adjustedDepth.toFixed(1)} m`,
          tideHeightM: tideHeight,
          tideValidTime: adjustment.validTime,
        },
      };
    }),
  };
}

async function imageDataFromBlob(blob) {
  if (typeof createImageBitmap !== "function" || typeof OffscreenCanvas !== "function") {
    const error = new Error("Worker image decoding is unavailable.");
    error.code = "IMAGE_DECODE_UNAVAILABLE";
    throw error;
  }
  const bitmap = await createImageBitmap(blob);
  try {
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const context = canvas.getContext("2d", { willReadFrequently: true });
    if (!context) throw new Error("The contour worker could not read the depth image.");
    context.drawImage(bitmap, 0, 0);
    return context.getImageData(0, 0, bitmap.width, bitmap.height);
  } finally {
    bitmap.close?.();
  }
}

export async function handleContourMessage(data) {
  if (data.type === "derive-blob") {
    const imageData = await imageDataFromBlob(data.imageBlob);
    storedContours = buildShadingContours({
      ...data,
      height: imageData.height,
      pixels: imageData.data.buffer,
      width: imageData.width,
    });
    storedSampleId = data.sampleId;
  } else if (data.type === "derive-pixels") {
    storedContours = buildShadingContours(data);
    storedSampleId = data.sampleId;
  } else if (data.type === "derive-gebco") {
    storedContours = deriveShallowContours(
      parseGebcoGrid(data.text),
      undefined,
      data.options,
    );
    storedSampleId = data.sampleId;
  } else if (data.type === "store") {
    storedContours = data.contours;
    storedSampleId = data.sampleId;
  } else if (data.type === "render" && data.sampleId !== storedSampleId) {
    throw new Error("The requested contour sample is no longer available.");
  }
  if (!storedContours || data.sampleId !== storedSampleId) {
    throw new Error("No contour sample is available to render.");
  }
  return {
    contours: renderContoursForDisplay(storedContours, data.display),
    sourceFeatureCount: storedContours.features.length,
  };
}

if (typeof self !== "undefined") {
  self.addEventListener("message", async (event) => {
    const { jobId, sampleId } = event.data;
    try {
      const result = await handleContourMessage(event.data);
      self.postMessage({ ...result, jobId, sampleId });
    } catch (error) {
      self.postMessage({
        code: error?.code,
        error: error instanceof Error ? error.message : "Contour generation failed.",
        jobId,
        sampleId,
      });
    }
  });
}
