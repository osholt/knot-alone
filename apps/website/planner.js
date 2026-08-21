import {
  buildGpx,
  formatBearing,
  formatDistance,
  formatDuration,
  gpxFileName,
  parseGpxDocument,
  passageSummary,
} from "./planner-core.mjs";
import {
  decodePlannerDraft,
  encodePlannerDraft,
  PLANNER_DRAFT_KEY,
} from "./planner-storage.mjs";
import {
  boundsContain,
  createContourRequest,
  createGebcoContourRequest,
  deriveShallowContours,
  EMODNET_COVERAGE,
  parseEmodnetGrid,
  parseGebcoGrid,
} from "./emodnet-contours.mjs";
import { windFieldGeoJson, windGrid, windRequestUrl } from "./wind-field.mjs";
import {
  currentGridDimensions,
  currentFieldGeoJson,
  currentSampleTimings,
  depthAdjustmentFor,
  estimatePassageWithCurrents,
  marineGrid,
  marineRequestUrl,
  routeSamplePlan,
  routeCurrentGeoJson,
  sampleMarineAt,
} from "./tide-current.mjs";

const MAP_STYLE_URLS = {
  light: "https://tiles.openfreemap.org/styles/liberty",
  dark: "https://tiles.openfreemap.org/styles/dark",
};
const POI_CATALOGUE_URL = "/data/sailing-pois.geojson";
const EMPTY_FEATURE_COLLECTION = Object.freeze({ type: "FeatureCollection", features: [] });
const EMODNET_PALETTES = {
  nautical: {
    tiles:
      "https://tiles.emodnet-bathymetry.eu/latest/mean_multicolour/web_mercator/{z}/{x}/{y}.png",
    paint: {
      "raster-opacity": 0.64,
      "raster-hue-rotate": 200,
      "raster-saturation": -0.15,
      "raster-contrast": 0.16,
      "raster-fade-duration": 0,
    },
  },
  multicolour: {
    tiles:
      "https://tiles.emodnet-bathymetry.eu/latest/mean_multicolour/web_mercator/{z}/{x}/{y}.png",
    paint: { "raster-opacity": 0.56, "raster-fade-duration": 0 },
  },
  "high-contrast": {
    tiles:
      "https://tiles.emodnet-bathymetry.eu/latest/mean_rainbowcolour/web_mercator/{z}/{x}/{y}.png",
    paint: { "raster-opacity": 0.58, "raster-contrast": 0.08, "raster-fade-duration": 0 },
  },
};
const EMODNET_CONTOUR_TILES =
  "https://ows.emodnet-bathymetry.eu/wms?service=WMS&version=1.1.1&request=GetMap&layers=emodnet%3Acontours&styles=contours&srs=EPSG%3A3857&bbox={bbox-epsg-3857}&width=256&height=256&format=image%2Fpng&transparent=true";
const GEBCO_BATHYMETRY_TILES =
  "https://wms.gebco.net/2026/mapserv?service=WMS&version=1.1.1&request=GetMap&layers=GEBCO_2026&styles=&srs=EPSG:3857&bbox={bbox-epsg-3857}&width=256&height=256&format=image/png&transparent=true";
const NOAA_CHART_TILES =
  "https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/WMSServer?service=WMS&version=1.3.0&request=GetMap&layers=0,1,2,3,4,5,6,7,8,9,10,11,12&styles=&crs=EPSG:3857&bbox={bbox-epsg-3857}&width=256&height=256&format=image/png&transparent=true";
const MAX_STOPS = 50;
const DEFAULT_CATEGORIES = ["harbour", "marina", "anchorage", "mooring", "tide_station"];

const elements = {
  actionStatus: document.querySelector("#action-status"),
  bathymetryVisible: document.querySelector("#bathymetry-visible"),
  clearLocal: document.querySelector("#clear-local"),
  clearPassage: document.querySelector("#clear-passage"),
  currentStatus: document.querySelector("#current-status"),
  currentVisible: document.querySelector("#current-visible"),
  depthPalette: document.querySelector("#depth-palette"),
  distance: document.querySelector("#passage-distance"),
  download: document.querySelector("#download-gpx"),
  draftStatus: document.querySelector("#draft-status"),
  emptyWaypoints: document.querySelector("#empty-waypoints"),
  gebcoVisible: document.querySelector("#gebco-visible"),
  importGpx: document.querySelector("#import-gpx"),
  legCount: document.querySelector("#passage-leg-count"),
  legTable: document.querySelector("#leg-table"),
  legTableWrap: document.querySelector("#leg-table-wrap"),
  mapCallout: document.querySelector("#map-callout"),
  noaaVisible: document.querySelector("#noaa-visible"),
  offshoreContoursVisible: document.querySelector("#offshore-contours-visible"),
  passageName: document.querySelector("#passage-name"),
  passageArrival: document.querySelector("#passage-arrival"),
  poiFilters: document.querySelector("#poi-filters"),
  poiSearch: document.querySelector("#poi-search"),
  poiResults: document.querySelector("#poi-results"),
  poisVisible: document.querySelector("#pois-visible"),
  publish: document.querySelector("#publish-plan"),
  seamarksVisible: document.querySelector("#seamarks-visible"),
  shallowContourStatus: document.querySelector("#shallow-contour-status"),
  shallowContoursVisible: document.querySelector("#shallow-contours-visible"),
  speedKnots: document.querySelector("#speed-knots"),
  startTime: document.querySelector("#start-time"),
  stillWaterDuration: document.querySelector("#still-water-duration"),
  tideDepthStatus: document.querySelector("#tide-depth-status"),
  duration: document.querySelector("#passage-duration"),
  waypointList: document.querySelector("#waypoint-list"),
  windStatus: document.querySelector("#wind-status"),
  windVisible: document.querySelector("#wind-visible"),
};

let stops = [];
let stopSequence = 0;
let markerInstances = [];
let poiCatalogue = { type: "FeatureCollection", features: [] };
let draftSaveTimer = null;
let mapReady = false;
let catalogueRequested = false;
let shallowContourData = EMPTY_FEATURE_COLLECTION;
let shallowContourBounds = null;
let shallowContourProvider = null;
let shallowContourAbortController = null;
let windAbortController = null;
let windRequestSequence = 0;
let currentFieldAbortController = null;
let currentFieldRequestSequence = 0;
let routeCurrentAbortController = null;
let routeCurrentRequestSequence = 0;
let routeCurrentEstimate = null;
let currentDepthAdjustment = null;
let marineDepthContext = null;
let marineRefreshTimer = null;
let marineRefreshPending = { field: false, route: false };

restoreDraft();
elements.depthPalette.disabled = !elements.bathymetryVisible.checked;

const map = new maplibregl.Map({
  container: "map",
  style: MAP_STYLE_URLS[currentTheme()],
  center: [-1.35, 50.76],
  zoom: 10,
  pitch: 0,
  bearing: 0,
  attributionControl: false,
});

map.addControl(new maplibregl.NavigationControl({ showCompass: true }), "bottom-left");
map.addControl(new maplibregl.ScaleControl({ unit: "nautical" }), "bottom-left");
map.addControl(new maplibregl.AttributionControl({ compact: true }), "bottom-left");

map.on("style.load", async () => {
  for (const [palette, configuration] of Object.entries(EMODNET_PALETTES)) {
    const sourceId = `emodnet-bathymetry-${palette}`;
    map.addSource(sourceId, {
      type: "raster",
      tiles: [configuration.tiles],
      tileSize: 256,
      minzoom: 0,
      maxzoom: 15,
      attribution:
        '<a href="https://emodnet.ec.europa.eu/en/bathymetry" target="_blank" rel="noreferrer">EMODnet Bathymetry DTM 2024</a>, EU, CC BY 4.0',
    });
    map.addLayer({
      id: `${sourceId}-layer`,
      type: "raster",
      source: sourceId,
      paint: configuration.paint,
      layout: {
        visibility:
          elements.bathymetryVisible.checked && elements.depthPalette.value === palette
            ? "visible"
            : "none",
      },
    });
  }

  map.addSource("emodnet-contours", {
    type: "raster",
    tiles: [EMODNET_CONTOUR_TILES],
    tileSize: 256,
    minzoom: 3,
    maxzoom: 15,
    attribution:
      '<a href="https://emodnet.ec.europa.eu/en/bathymetry" target="_blank" rel="noreferrer">EMODnet depth contours</a>, EU, CC BY 4.0',
  });
  map.addLayer({
    id: "emodnet-contours-layer",
    type: "raster",
    source: "emodnet-contours",
    paint: { "raster-opacity": 0.88 },
    layout: { visibility: elements.offshoreContoursVisible.checked ? "visible" : "none" },
  });

  map.addSource("gebco-bathymetry", {
    type: "raster",
    tiles: [GEBCO_BATHYMETRY_TILES],
    tileSize: 256,
    minzoom: 0,
    maxzoom: 8,
    attribution:
      '<a href="https://www.gebco.net/" target="_blank" rel="noreferrer">GEBCO 2026 Grid</a>',
  });
  map.addLayer({
    id: "gebco-bathymetry-layer",
    type: "raster",
    source: "gebco-bathymetry",
    maxzoom: 8.5,
    paint: {
      "raster-opacity": 0.38,
      "raster-resampling": "linear",
      "raster-contrast": -0.08,
      "raster-fade-duration": 0,
    },
    layout: { visibility: elements.gebcoVisible.checked ? "visible" : "none" },
  });

  map.addSource("noaa-charts", {
    type: "raster",
    tiles: [NOAA_CHART_TILES],
    tileSize: 256,
    minzoom: 2,
    maxzoom: 18,
    attribution:
      '<a href="https://nauticalcharts.noaa.gov/data/gis-data-and-services.html" target="_blank" rel="noreferrer">NOAA Chart Display Service</a>',
  });
  map.addLayer({
    id: "noaa-charts-layer",
    type: "raster",
    source: "noaa-charts",
    paint: { "raster-opacity": 0.94 },
    layout: { visibility: elements.noaaVisible.checked ? "visible" : "none" },
  });

  map.addSource("shallow-contours", {
    type: "geojson",
    data: shallowContourData,
    attribution:
      '<a href="https://emodnet.ec.europa.eu/en/bathymetry" target="_blank" rel="noreferrer">EMODnet Bathymetry DTM 2024</a>, EU, CC BY 4.0 · <a href="https://www.gebco.net/data-products/gridded-bathymetry-data" target="_blank" rel="noreferrer">GEBCO 2026 Grid</a> · current-view derived 2–30 m contours',
  });
  map.addLayer({
    id: "shallow-contours-layer",
    type: "line",
    source: "shallow-contours",
    minzoom: 8,
    layout: {
      visibility: elements.shallowContoursVisible.checked ? "visible" : "none",
      "line-cap": "round",
      "line-join": "round",
      "line-sort-key": ["get", "depthM"],
    },
    paint: {
      "line-color": [
        "match",
        ["get", "depthM"],
        2, "#c44230",
        5, "#e27932",
        10, "#b18b20",
        20, "#25789a",
        30, "#395f9e",
        "#25789a",
      ],
      "line-width": [
        "interpolate", ["linear"], ["zoom"],
        8, ["match", ["get", "depthM"], 2, 1.25, 5, 1.15, 1],
        15, ["match", ["get", "depthM"], 2, 2.7, 5, 2.35, 1.8],
      ],
      "line-opacity": 0.92,
    },
  });
  map.addLayer({
    id: "shallow-contour-labels",
    type: "symbol",
    source: "shallow-contours",
    minzoom: 10,
    layout: {
      visibility: elements.shallowContoursVisible.checked ? "visible" : "none",
      "symbol-placement": "line",
      "symbol-spacing": 310,
      "text-field": ["coalesce", ["get", "displayLabel"], ["get", "label"]],
      "text-size": 10,
      "text-allow-overlap": false,
      "text-ignore-placement": false,
    },
    paint: {
      "text-color": currentTheme() === "dark" ? "#d8edf0" : "#153f4c",
      "text-halo-color": currentTheme() === "dark" ? "#102126" : "#fffdf7",
      "text-halo-width": 1.5,
    },
  });

  map.addSource("wind-field", { type: "geojson", data: EMPTY_FEATURE_COLLECTION });
  map.addLayer({
    id: "wind-field-arrows",
    type: "line",
    source: "wind-field",
    filter: ["==", ["get", "kind"], "arrow"],
    minzoom: 3,
    layout: {
      visibility: elements.windVisible.checked ? "visible" : "none",
      "line-cap": "round",
      "line-join": "round",
    },
    paint: {
      "line-color": [
        "step", ["get", "speedKnots"],
        "#2b82b8", 10, "#2b9b78", 18, "#d18a2d", 28, "#d14c3a",
      ],
      "line-width": ["interpolate", ["linear"], ["get", "speedKnots"], 0, 2, 35, 4.5],
      "line-opacity": 0.95,
    },
  });
  map.addLayer({
    id: "wind-field-labels",
    type: "symbol",
    source: "wind-field",
    filter: ["==", ["get", "kind"], "label"],
    minzoom: 4,
    layout: {
      visibility: elements.windVisible.checked ? "visible" : "none",
      "text-field": ["get", "speedLabel"],
      "text-size": 10,
      "text-offset": [0, 1.35],
      "text-allow-overlap": false,
    },
    paint: {
      "text-color": currentTheme() === "dark" ? "#f1fbfb" : "#113b47",
      "text-halo-color": currentTheme() === "dark" ? "#0b1c22" : "#fffdf7",
      "text-halo-width": 1.6,
    },
  });

  map.addSource("current-field", {
    type: "geojson",
    data: EMPTY_FEATURE_COLLECTION,
    attribution:
      '<a href="https://open-meteo.com/en/docs/marine-weather-api" target="_blank" rel="noreferrer">Open-Meteo marine model</a>, CC BY 4.0',
  });
  map.addLayer({
    id: "current-field-arrows",
    type: "line",
    source: "current-field",
    filter: ["==", ["get", "kind"], "current-arrow"],
    minzoom: 3,
    layout: {
      visibility: elements.currentVisible.checked ? "visible" : "none",
      "line-cap": "round",
      "line-join": "round",
    },
    paint: {
      "line-color": [
        "interpolate", ["linear"], ["coalesce", ["get", "forecastWeight"], 0],
        0, "#078c9b", 0.5, "#486fc0", 1, "#8a4faf",
      ],
      "line-width": [
        "interpolate", ["linear"], ["zoom"],
        3, ["interpolate", ["linear"], ["get", "speedKnots"], 0, 2.2, 4, 4.6],
        14, ["interpolate", ["linear"], ["get", "speedKnots"], 0, 3.2, 4, 6.2],
      ],
      "line-opacity": 0.92,
    },
  });
  map.addLayer({
    id: "current-field-labels",
    type: "symbol",
    source: "current-field",
    filter: ["==", ["get", "kind"], "current-label"],
    minzoom: 4,
    layout: {
      visibility: elements.currentVisible.checked ? "visible" : "none",
      "text-field": ["get", "speedLabel"],
      "text-size": ["interpolate", ["linear"], ["zoom"], 4, 11.5, 10, 13, 14, 14.5],
      "text-offset": [0, -1.35],
      "text-allow-overlap": false,
    },
    paint: {
      "text-color": [
        "interpolate", ["linear"], ["coalesce", ["get", "forecastWeight"], 0],
        0, currentTheme() === "dark" ? "#a9f0f2" : "#075b64",
        0.5, currentTheme() === "dark" ? "#cad7ff" : "#304f96",
        1, currentTheme() === "dark" ? "#e4c7f5" : "#603377",
      ],
      "text-halo-color": currentTheme() === "dark" ? "#0b1c22" : "#fffdf7",
      "text-halo-width": 1.6,
    },
  });

  map.addSource("seamarks", {
    type: "raster",
    tiles: ["https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png"],
    tileSize: 256,
    minzoom: 3,
    maxzoom: 18,
    attribution:
      '<a href="https://www.openseamap.org/" target="_blank" rel="noreferrer">OpenSeaMap</a> · ' +
      '<a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap contributors</a>',
  });
  map.addLayer({
    id: "seamarks-layer",
    type: "raster",
    source: "seamarks",
    paint: { "raster-opacity": 0.9 },
    layout: { visibility: elements.seamarksVisible.checked ? "visible" : "none" },
  });

  map.addSource("marine-pois", {
    type: "geojson",
    data: poiCatalogue,
    cluster: true,
    clusterMaxZoom: 10,
    clusterRadius: 38,
  });
  map.addLayer({
    id: "marine-poi-clusters",
    type: "circle",
    source: "marine-pois",
    filter: ["has", "point_count"],
    paint: {
      "circle-color": "#0c5f78",
      "circle-radius": ["step", ["get", "point_count"], 14, 20, 18, 80, 22],
      "circle-stroke-color": "#fffdf7",
      "circle-stroke-width": 3,
    },
  });
  map.addLayer({
    id: "marine-poi-cluster-count",
    type: "symbol",
    source: "marine-pois",
    filter: ["has", "point_count"],
    layout: { "text-field": ["get", "point_count_abbreviated"], "text-size": 11 },
    paint: { "text-color": "#ffffff" },
  });
  map.addLayer({
    id: "marine-poi-points",
    type: "circle",
    source: "marine-pois",
    filter: ["!", ["has", "point_count"]],
    paint: {
      "circle-color": [
        "match", ["get", "category"],
        "anchorage", "#e97451",
        "marina", "#0c5f78",
        "harbour", "#0c5f78",
        "mooring", "#4b8f8a",
        "tide_station", "#6d55a5",
        "slipway", "#a27035",
        "structure", "#59676c",
        "#7f9a70",
      ],
      "circle-radius": ["interpolate", ["linear"], ["zoom"], 7, 4, 13, 7],
      "circle-stroke-color": "#fffdf7",
      "circle-stroke-width": 2,
    },
  });

  map.addSource("passage-route", { type: "geojson", data: routeGeoJson() });
  map.addLayer({
    id: "passage-route-casing",
    type: "line",
    source: "passage-route",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": "#fffdf7", "line-width": 8, "line-opacity": 0.88 },
  });
  map.addLayer({
    id: "passage-route-line",
    type: "line",
    source: "passage-route",
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": "#e15f3b", "line-width": 4, "line-dasharray": [2.2, 1.2] },
  });

  map.addSource("route-current", { type: "geojson", data: routeCurrentGeoJson(routeCurrentEstimate) });
  map.addLayer({
    id: "route-drift-line",
    type: "line",
    source: "route-current",
    filter: ["==", ["get", "kind"], "drift-line"],
    minzoom: 4,
    layout: {
      visibility: elements.currentVisible.checked ? "visible" : "none",
      "line-cap": "round",
      "line-join": "round",
    },
    paint: {
      "line-color": "#c54e8f",
      "line-width": ["interpolate", ["linear"], ["zoom"], 4, 2, 13, 3.5],
      "line-dasharray": [1.5, 1.5],
      "line-opacity": 0.9,
    },
  });
  map.addLayer({
    id: "route-current-arrows",
    type: "line",
    source: "route-current",
    filter: ["==", ["get", "kind"], "course-to-steer-arrow"],
    minzoom: 4,
    layout: {
      visibility: elements.currentVisible.checked ? "visible" : "none",
      "line-cap": "round",
      "line-join": "round",
    },
    paint: {
      "line-color": "#f09a35",
      "line-width": ["interpolate", ["linear"], ["zoom"], 4, 3.4, 13, 5],
      "line-opacity": 0.98,
    },
  });
  map.addLayer({
    id: "route-current-labels",
    type: "symbol",
    source: "route-current",
    filter: ["==", ["get", "kind"], "course-to-steer-label"],
    minzoom: 5,
    layout: {
      visibility: elements.currentVisible.checked ? "visible" : "none",
      "text-field": ["get", "speedLabel"],
      "text-size": ["interpolate", ["linear"], ["zoom"], 5, 11.5, 12, 13.5],
      "text-offset": [0, 1.5],
      "text-allow-overlap": false,
    },
    paint: {
      "text-color": currentTheme() === "dark" ? "#ffd8a8" : "#87470c",
      "text-halo-color": currentTheme() === "dark" ? "#0b1c22" : "#fffdf7",
      "text-halo-width": 1.7,
    },
  });

  mapReady = true;
  syncChartContextLayers();
  updatePoiLayer();
  renderPassage();
  updateShallowContours();
  if (elements.windVisible.checked) updateWindField();
  if (elements.currentVisible.checked) {
    updateCurrentField();
    updateRouteCurrentEstimate();
  }
  if (!catalogueRequested) {
    catalogueRequested = true;
    await loadPoiCatalogue();
  }
});

window.addEventListener("tideandseekthemechange", (event) => {
  const theme = event.detail?.theme;
  if (!MAP_STYLE_URLS[theme]) return;
  mapReady = false;
  map.setStyle(MAP_STYLE_URLS[theme]);
});

map.on("moveend", () => {
  updateShallowContours();
  if (elements.windVisible.checked) updateWindField();
  if (elements.currentVisible.checked) updateCurrentField();
});

map.on("click", async (event) => {
  if (event.originalEvent.target?.closest?.(".maplibregl-marker, .maplibregl-ctrl")) return;

  const currentFeature = elements.currentVisible.checked && map.getLayer("current-field-arrows")
    ? map.queryRenderedFeatures(event.point, {
        layers: [
          "route-current-arrows",
          "route-current-labels",
          "current-field-arrows",
          "current-field-labels",
        ],
      })[0]
    : null;
  if (currentFeature) {
    showCurrentPopup(event.lngLat, currentFeature.properties);
    return;
  }

  const windFeature = elements.windVisible.checked && map.getLayer("wind-field-arrows")
    ? map.queryRenderedFeatures(event.point, {
        layers: ["wind-field-arrows", "wind-field-labels"],
      })[0]
    : null;
  if (windFeature) {
    showWindPopup(event.lngLat, windFeature.properties);
    return;
  }

  const cluster = map.getLayer("marine-poi-clusters")
    ? map.queryRenderedFeatures(event.point, { layers: ["marine-poi-clusters"] })[0]
    : null;
  if (cluster) {
    const zoom = await map.getSource("marine-pois").getClusterExpansionZoom(
      cluster.properties.cluster_id,
    );
    map.easeTo({ center: cluster.geometry.coordinates, zoom });
    return;
  }
  const feature = map.getLayer("marine-poi-points")
    ? map.queryRenderedFeatures(event.point, { layers: ["marine-poi-points"] })[0]
    : null;
  if (feature) {
    showPoiPopup(feature);
    return;
  }
  addStop({
    name: `Waypoint ${stops.length + 1}`,
    notes: "",
    longitude: event.lngLat.lng,
    latitude: event.lngLat.lat,
  });
});

for (const layerId of [
  "marine-poi-clusters",
  "marine-poi-points",
  "wind-field-arrows",
  "wind-field-labels",
  "current-field-arrows",
  "current-field-labels",
  "route-drift-line",
  "route-current-arrows",
  "route-current-labels",
]) {
  map.on("mouseenter", layerId, () => { map.getCanvas().style.cursor = "pointer"; });
  map.on("mouseleave", layerId, () => { map.getCanvas().style.cursor = ""; });
}

elements.passageName.addEventListener("input", () => scheduleDraftSave());
elements.speedKnots.addEventListener("input", () => {
  invalidateRouteCurrentEstimate();
  renderSummary();
  scheduleMarineRefresh({ field: true, route: true });
  scheduleDraftSave();
});
elements.startTime.addEventListener("change", () => {
  invalidateRouteCurrentEstimate();
  currentDepthAdjustment = null;
  renderSummary();
  syncAdjustedContourData();
  scheduleMarineRefresh({ field: true, route: true }, 0);
  scheduleDraftSave();
});
elements.poiSearch.addEventListener("input", renderPoiResults);
elements.poiFilters.addEventListener("change", () => {
  updatePoiLayer();
  renderPoiResults();
  scheduleDraftSave();
});
elements.seamarksVisible.addEventListener("change", () => {
  setLayerVisibility("seamarks-layer", elements.seamarksVisible.checked);
  scheduleDraftSave();
});
elements.bathymetryVisible.addEventListener("change", () => {
  syncChartContextLayers();
  scheduleDraftSave();
});
elements.depthPalette.addEventListener("change", () => {
  syncChartContextLayers();
  scheduleDraftSave();
});
elements.shallowContoursVisible.addEventListener("change", () => {
  syncChartContextLayers();
  if (elements.shallowContoursVisible.checked) updateShallowContours(true);
  scheduleDraftSave();
});
elements.offshoreContoursVisible.addEventListener("change", () => {
  syncChartContextLayers();
  scheduleDraftSave();
});
elements.gebcoVisible.addEventListener("change", () => {
  syncChartContextLayers();
  scheduleDraftSave();
});
elements.noaaVisible.addEventListener("change", () => {
  syncChartContextLayers();
  scheduleDraftSave();
});
elements.poisVisible.addEventListener("change", updatePoiLayer);
elements.windVisible.addEventListener("change", () => {
  setLayerVisibility("wind-field-arrows", elements.windVisible.checked);
  setLayerVisibility("wind-field-labels", elements.windVisible.checked);
  if (elements.windVisible.checked) {
    updateWindField();
  } else {
    windAbortController?.abort();
    elements.windStatus.textContent = "Wind field hidden. Turn it on to load current model wind.";
  }
  scheduleDraftSave();
});
elements.currentVisible.addEventListener("change", () => {
  syncChartContextLayers();
  if (elements.currentVisible.checked) {
    scheduleMarineRefresh({ field: true, route: true }, 0);
  } else {
    currentFieldAbortController?.abort();
    routeCurrentAbortController?.abort();
    elements.currentStatus.textContent = "Current field hidden.";
  }
  scheduleDraftSave();
});

function syncChartContextLayers() {
  elements.depthPalette.disabled = !elements.bathymetryVisible.checked;
  if (!mapReady) return;
  for (const palette of Object.keys(EMODNET_PALETTES)) {
    setLayerVisibility(
      `emodnet-bathymetry-${palette}-layer`,
      elements.bathymetryVisible.checked && elements.depthPalette.value === palette
        ? true
        : false,
    );
  }
  setLayerVisibility("emodnet-contours-layer", elements.offshoreContoursVisible.checked);
  setLayerVisibility("shallow-contours-layer", elements.shallowContoursVisible.checked);
  setLayerVisibility("shallow-contour-labels", elements.shallowContoursVisible.checked);
  setLayerVisibility("gebco-bathymetry-layer", elements.gebcoVisible.checked);
  setLayerVisibility("noaa-charts-layer", elements.noaaVisible.checked);
  setLayerVisibility("current-field-arrows", elements.currentVisible.checked);
  setLayerVisibility("current-field-labels", elements.currentVisible.checked);
  setLayerVisibility("route-drift-line", elements.currentVisible.checked);
  setLayerVisibility("route-current-arrows", elements.currentVisible.checked);
  setLayerVisibility("route-current-labels", elements.currentVisible.checked);
}

function setLayerVisibility(layerId, visible) {
  if (!mapReady || !map.getLayer(layerId)) return;
  map.setLayoutProperty(layerId, "visibility", visible ? "visible" : "none");
}
elements.clearPassage.addEventListener("click", () => {
  stops = [];
  renderPassage();
  elements.actionStatus.textContent = "Passage cleared.";
});
elements.clearLocal.addEventListener("click", () => {
  localStorage.removeItem(PLANNER_DRAFT_KEY);
  stops = [];
  elements.passageName.value = "Solent passage";
  elements.speedKnots.value = "5";
  elements.bathymetryVisible.checked = true;
  elements.depthPalette.value = "nautical";
  elements.shallowContoursVisible.checked = true;
  elements.offshoreContoursVisible.checked = false;
  elements.gebcoVisible.checked = false;
  elements.noaaVisible.checked = false;
  elements.seamarksVisible.checked = true;
  elements.windVisible.checked = false;
  elements.currentVisible.checked = true;
  elements.startTime.value = defaultStartTimeValue();
  invalidateRouteCurrentEstimate();
  currentDepthAdjustment = null;
  syncChartContextLayers();
  setLayerVisibility("seamarks-layer", true);
  setLayerVisibility("wind-field-arrows", false);
  setLayerVisibility("wind-field-labels", false);
  renderPassage();
  scheduleMarineRefresh({ field: true, route: true }, 0);
  clearTimeout(draftSaveTimer);
  localStorage.removeItem(PLANNER_DRAFT_KEY);
  elements.draftStatus.textContent = "Saved planner data cleared from this device.";
});
elements.download.addEventListener("click", downloadGpx);
elements.publish.addEventListener("click", publishPlan);
elements.importGpx.addEventListener("change", importGpx);

function addStop(stop) {
  if (stops.length >= MAX_STOPS) {
    elements.actionStatus.textContent = `A passage can contain up to ${MAX_STOPS} waypoints.`;
    return;
  }
  stops.push({
    id: ++stopSequence,
    name: String(stop.name || `Waypoint ${stops.length + 1}`).slice(0, 100),
    notes: String(stop.notes || "").slice(0, 500),
    longitude: Number(stop.longitude),
    latitude: Number(stop.latitude),
  });
  renderPassage();
}

function renderPassage() {
  invalidateRouteCurrentEstimate();
  renderWaypointList();
  renderSummary();
  syncMapRoute();
  syncMarkers();
  elements.emptyWaypoints.hidden = stops.length > 0;
  elements.mapCallout.hidden = stops.length > 0;
  elements.download.disabled = stops.length < 2;
  elements.publish.disabled = stops.length < 2;
  scheduleMarineRefresh({ field: true, route: true });
  scheduleDraftSave();
}

function renderWaypointList() {
  elements.waypointList.replaceChildren();
  stops.forEach((stop, index) => {
    const row = document.createElement("li");
    row.className = "waypoint-row";

    const number = document.createElement("span");
    number.className = "waypoint-number";
    number.textContent = String(index + 1);

    const fields = document.createElement("div");
    fields.className = "waypoint-fields";
    const name = document.createElement("input");
    name.value = stop.name;
    name.maxLength = 100;
    name.setAttribute("aria-label", `Waypoint ${index + 1} name`);
    name.addEventListener("input", () => {
      stop.name = name.value;
      scheduleDraftSave();
    });
    const notes = document.createElement("input");
    notes.value = stop.notes;
    notes.maxLength = 500;
    notes.placeholder = "Notes, tide gate or approach check";
    notes.setAttribute("aria-label", `Waypoint ${index + 1} notes`);
    notes.addEventListener("input", () => {
      stop.notes = notes.value;
      scheduleDraftSave();
    });
    fields.append(name, notes);

    const actions = document.createElement("div");
    actions.className = "waypoint-actions";
    actions.append(
      waypointAction("↑", "Move waypoint earlier", index === 0, () => moveStop(index, -1)),
      waypointAction("↓", "Move waypoint later", index === stops.length - 1, () => moveStop(index, 1)),
      waypointAction("×", "Remove waypoint", false, () => removeStop(index), "remove-waypoint"),
    );
    row.append(number, fields, actions);
    elements.waypointList.append(row);
  });
}

function waypointAction(label, accessibleName, disabled, action, className = "") {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = label;
  button.title = accessibleName;
  button.setAttribute("aria-label", accessibleName);
  button.disabled = disabled;
  button.className = className;
  button.addEventListener("click", action);
  return button;
}

function moveStop(index, direction) {
  const next = index + direction;
  if (next < 0 || next >= stops.length) return;
  [stops[index], stops[next]] = [stops[next], stops[index]];
  renderPassage();
}

function removeStop(index) {
  stops.splice(index, 1);
  renderPassage();
}

function renderSummary() {
  const summary = passageSummary(stops, Number(elements.speedKnots.value));
  const adjusted = routeCurrentEstimate?.complete ? routeCurrentEstimate : null;
  const durationSeconds = adjusted?.durationSeconds ?? summary.durationSeconds;
  const start = selectedStartTime();
  elements.distance.textContent = stops.length > 1 ? formatDistance(summary.distanceMetres) : "—";
  elements.duration.textContent = stops.length > 1 ? formatDuration(durationSeconds) : "—";
  elements.stillWaterDuration.textContent = stops.length > 1 && adjusted
    ? `Still water: ${formatDuration(summary.durationSeconds)}`
    : stops.length > 1 ? "Still-water estimate; loading model current…" : "";
  elements.passageArrival.textContent = stops.length > 1 && start && Number.isFinite(durationSeconds)
    ? formatPassageTime(new Date(start.getTime() + durationSeconds * 1000))
    : "—";
  elements.legCount.textContent = String(summary.legs.length);
  elements.legTableWrap.hidden = summary.legs.length === 0;
  elements.legTable.replaceChildren();
  for (const leg of summary.legs) {
    const modelLeg = routeCurrentEstimate?.legs?.find((value) => value.index === leg.index);
    const current = Number.isFinite(modelLeg?.currentSpeedKnots)
      ? `${modelLeg.currentSpeedKnots.toFixed(1)} kn →${String(Math.round(modelLeg.currentDirectionTowards)).padStart(3, "0")}°T · ${formatSignedKnots(modelLeg.alongKnots)} along · CTS ${String(Math.round(modelLeg.headingDegrees)).padStart(3, "0")}°T · level ${formatSignedMetres(modelLeg.seaLevelMsl)} MSL`
      : "Loading…";
    const eta = modelLeg?.arrivalTime ? formatPassageTime(new Date(modelLeg.arrivalTime)) : "—";
    const row = document.createElement("tr");
    for (const value of [
      `${leg.index}. ${leg.from.name || "Waypoint"} → ${leg.to.name || "Waypoint"}`,
      formatBearing(leg.bearingDegrees),
      formatDistance(leg.distanceMetres),
      current,
      eta,
    ]) {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.append(cell);
    }
    elements.legTable.append(row);
  }
}

function syncMapRoute() {
  if (!mapReady) return;
  map.getSource("passage-route").setData(routeGeoJson());
}

function routeGeoJson() {
  if (stops.length < 2) {
    return { type: "FeatureCollection", features: [] };
  }
  return {
    type: "Feature",
    properties: {},
    geometry: {
      type: "LineString",
      coordinates: stops.map((stop) => [stop.longitude, stop.latitude]),
    },
  };
}

function syncMarkers() {
  if (!mapReady) return;
  for (const marker of markerInstances) marker.remove();
  markerInstances = stops.map((stop, index) => {
    const markerElement = document.createElement("div");
    markerElement.className = "passage-marker";
    const number = document.createElement("span");
    number.textContent = String(index + 1);
    markerElement.append(number);
    const marker = new maplibregl.Marker({ element: markerElement, draggable: true })
      .setLngLat([stop.longitude, stop.latitude])
      .addTo(map);
    marker.on("dragend", () => {
      const position = marker.getLngLat();
      stop.longitude = position.lng;
      stop.latitude = position.lat;
      invalidateRouteCurrentEstimate();
      renderSummary();
      syncMapRoute();
      scheduleMarineRefresh({ field: true, route: true });
      scheduleDraftSave();
    });
    return marker;
  });
}

async function loadPoiCatalogue() {
  try {
    const response = await fetch(POI_CATALOGUE_URL, { headers: { Accept: "application/geo+json" } });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    if (data?.type !== "FeatureCollection" || !Array.isArray(data.features)) {
      throw new Error("invalid catalogue");
    }
    poiCatalogue = data;
    map.getSource("marine-pois").setData(poiCatalogue);
    updatePoiLayer();
    renderPoiResults();
  } catch {
    elements.poiResults.textContent = "The sailing-place catalogue could not be loaded.";
  }
}

function selectedCategories() {
  const selected = Array.from(elements.poiFilters.querySelectorAll('input[type="checkbox"]:checked'))
    .map((input) => input.value);
  return selected.length > 0 ? selected : [];
}

function updatePoiLayer() {
  if (!mapReady) return;
  const visibility = elements.poisVisible.checked ? "visible" : "none";
  const categories = selectedCategories();
  map.getSource("marine-pois").setData({
    ...poiCatalogue,
    features: poiCatalogue.features.filter((feature) =>
      categories.includes(feature.properties?.category),
    ),
  });
  for (const layer of ["marine-poi-clusters", "marine-poi-cluster-count", "marine-poi-points"]) {
    map.setLayoutProperty(layer, "visibility", visibility);
  }
}

function renderPoiResults() {
  const query = elements.poiSearch.value.trim().toLocaleLowerCase("en-GB");
  const categories = new Set(selectedCategories());
  const features = poiCatalogue.features
    .filter((feature) => categories.has(feature.properties?.category))
    .filter((feature) => {
      if (!query) return true;
      const values = [
        feature.properties?.name,
        feature.properties?.category,
        feature.properties?.facility,
        feature.properties?.operator,
      ].join(" ").toLocaleLowerCase("en-GB");
      return values.includes(query);
    })
    .sort((first, second) => String(first.properties?.name).localeCompare(String(second.properties?.name)))
    .slice(0, 60);

  elements.poiResults.replaceChildren();
  if (features.length === 0) {
    elements.poiResults.textContent = poiCatalogue.features.length === 0
      ? "Loading sailing places…"
      : "No matching sailing places in the selected starter coverage.";
    return;
  }
  for (const feature of features) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "poi-result";
    const dot = document.createElement("i");
    dot.className = "poi-dot";
    const name = document.createElement("span");
    name.textContent = feature.properties?.name || categoryLabel(feature.properties?.category);
    const category = document.createElement("small");
    category.textContent = categoryLabel(feature.properties?.category);
    button.append(dot, name, category);
    button.addEventListener("click", () => {
      map.easeTo({ center: feature.geometry.coordinates, zoom: Math.max(map.getZoom(), 13) });
      showPoiPopup(feature);
    });
    elements.poiResults.append(button);
  }
}

function showPoiPopup(feature) {
  const properties = feature.properties || {};
  const container = document.createElement("div");
  container.className = "marine-popup";
  const heading = document.createElement("h3");
  heading.textContent = properties.name || categoryLabel(properties.category);
  const detail = document.createElement("p");
  detail.textContent = [categoryLabel(properties.category), properties.facility]
    .filter(Boolean).join(" · ");
  const provenance = document.createElement("p");
  provenance.textContent = `${properties.sourceName || "OpenStreetMap"} · ${properties.sourceUpdated || "update not stated"}`;
  container.append(heading, detail, provenance);
  if (properties.sourceUrl) {
    const source = document.createElement("a");
    source.href = properties.sourceUrl;
    source.target = "_blank";
    source.rel = "noreferrer";
    source.textContent = "View source";
    container.append(source);
  }
  const add = document.createElement("button");
  add.type = "button";
  add.textContent = "Add as waypoint";
  add.addEventListener("click", () => {
    addStop({
      name: properties.name || categoryLabel(properties.category),
      notes: `Source: ${properties.sourceName || "OpenStreetMap"}. Verify before departure.`,
      longitude: feature.geometry.coordinates[0],
      latitude: feature.geometry.coordinates[1],
    });
    popup.remove();
  });
  container.append(add);
  const popup = new maplibregl.Popup({ offset: 12, closeButton: true })
    .setLngLat(feature.geometry.coordinates)
    .setDOMContent(container)
    .addTo(map);
}

function categoryLabel(value) {
  return {
    harbour: "harbour",
    marina: "marina",
    anchorage: "anchorage",
    mooring: "mooring",
    slipway: "slipway",
    service: "small-craft service",
    structure: "lock or bridge",
    tide_station: "tide station",
  }[value] || "sailing place";
}

function downloadGpx() {
  try {
    const gpx = buildGpx({ passageName: elements.passageName.value, stops });
    const url = URL.createObjectURL(new Blob([gpx], { type: "application/gpx+xml" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = gpxFileName(elements.passageName.value);
    document.body.append(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
    elements.actionStatus.textContent = "GPX downloaded. Check it against current official information before use.";
  } catch (error) {
    elements.actionStatus.textContent = error.message;
  }
}

async function publishPlan() {
  elements.publish.disabled = true;
  elements.actionStatus.textContent = "Creating a short plan code…";
  try {
    const gpx = buildGpx({ passageName: elements.passageName.value, stops });
    const configuredOrigin = document.querySelector('meta[name="tide-and-seek-api"]')
      ?.content?.trim().replace(/\/$/, "");
    const endpoint = `${configuredOrigin || ""}/api/v1/plans`;
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ name: elements.passageName.value.trim() || null, gpx }),
    });
    if (!response.ok) throw new Error(`The plan service returned HTTP ${response.status}.`);
    const result = await response.json();
    if (!/^[A-Z0-9]{4,16}$/.test(result.code || "")) throw new Error("The plan service returned an invalid code.");
    elements.actionStatus.textContent = `Plan code ${result.code}. Enter it in Tide and Seek; it expires ${formatExpiry(result.expiresAt)}.`;
  } catch (error) {
    elements.actionStatus.textContent = `Could not create a plan code. ${error.message}`;
  } finally {
    elements.publish.disabled = stops.length < 2;
  }
}

async function importGpx() {
  const file = elements.importGpx.files?.[0];
  if (!file) return;
  if (file.size > 10 * 1024 * 1024) {
    elements.actionStatus.textContent = "The GPX file exceeds the 10 MB import limit.";
    return;
  }
  try {
    const text = await file.text();
    if (text.toUpperCase().includes("<!DOCTYPE")) throw new Error("GPX files containing a document type declaration are not accepted.");
    const document = new DOMParser().parseFromString(text, "application/xml");
    const parsed = parseGpxDocument(document);
    stops = parsed.stops.slice(0, MAX_STOPS).map((stop) => ({ ...stop, id: ++stopSequence }));
    elements.passageName.value = parsed.name.slice(0, 100);
    renderPassage();
    fitPassage();
    elements.actionStatus.textContent = stops.length < parsed.stops.length
      ? `Imported the first ${MAX_STOPS} GPX positions as editable waypoints.`
      : `Imported ${stops.length} GPX positions as editable waypoints.`;
  } catch (error) {
    elements.actionStatus.textContent = `Could not import GPX. ${error.message}`;
  } finally {
    elements.importGpx.value = "";
  }
}

async function updateWindField() {
  if (!mapReady || !elements.windVisible.checked) return;
  windAbortController?.abort();
  windAbortController = new AbortController();
  const requestSequence = ++windRequestSequence;
  const bounds = visibleMapBounds();
  const points = windGrid(bounds);
  elements.windStatus.textContent = "Loading current model wind across this map…";
  try {
    const response = await fetch(windRequestUrl(points), {
      headers: { Accept: "application/json" },
      signal: windAbortController.signal,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    if (requestSequence !== windRequestSequence) return;
    const field = windFieldGeoJson(points, data, bounds);
    if (field.geojson.features.length === 0) throw new Error("unreadable forecast values");
    map.getSource("wind-field")?.setData(field.geojson);
    elements.windStatus.textContent = `${points.length} model samples · valid ${field.validTime} UTC · arrows point downwind; labels show knots. Tap an arrow for direction and gusts.`;
  } catch (error) {
    if (error.name === "AbortError") return;
    elements.windStatus.textContent = `Wind forecast unavailable (${error.message}).`;
  }
}

function showWindPopup(position, properties) {
  const speed = Math.round(Number(properties.speedKnots));
  const direction = Math.round(Number(properties.directionFrom));
  const gust = Math.round(Number(properties.gustKnots));
  const container = document.createElement("div");
  container.className = "marine-popup wind-popup";
  const heading = document.createElement("h3");
  heading.textContent = `${speed} kn from ${String(direction).padStart(3, "0")}°T`;
  const detail = document.createElement("p");
  detail.textContent = `Gusting ${gust} kn · valid ${properties.validTime} UTC`;
  const warning = document.createElement("p");
  warning.textContent = "Open-Meteo model forecast, not an observation.";
  container.append(heading, detail, warning);
  new maplibregl.Popup({ offset: 10, closeButton: true })
    .setLngLat(position)
    .setDOMContent(container)
    .addTo(map);
}

async function updateCurrentField() {
  if (!mapReady || !elements.currentVisible.checked) return;
  const start = selectedStartTime();
  if (!start) {
    elements.currentStatus.textContent = "Choose a valid passage start time to load currents.";
    return;
  }
  currentFieldAbortController?.abort();
  currentFieldAbortController = new AbortController();
  const requestSequence = ++currentFieldRequestSequence;
  const bounds = visibleMapBounds();
  const canvas = map.getCanvas();
  const dimensions = currentGridDimensions(canvas.clientWidth, canvas.clientHeight, map.getZoom());
  const points = marineGrid(bounds, dimensions.columns, dimensions.rows);
  const timings = currentSampleTimings(points, new Date(), routeCurrentEstimate);
  const requestedTimes = [start, ...timings.map((timing) => new Date(timing.sampleTime))];
  const rangeStart = new Date(Math.min(...requestedTimes.map((date) => date.getTime())) - 3_600_000);
  const rangeEnd = new Date(Math.max(...requestedTimes.map((date) => date.getTime())) + 3_600_000);
  elements.currentStatus.textContent = "Loading the adaptive current field and route-time forecast…";
  try {
    const response = await fetch(
      marineRequestUrl(points, rangeStart, rangeEnd),
      {
        headers: { Accept: "application/json" },
        signal: currentFieldAbortController.signal,
      },
    );
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    if (requestSequence !== currentFieldRequestSequence) return;
    const field = currentFieldGeoJson(
      points,
      data,
      bounds,
      timings,
      dimensions.columns,
      dimensions.rows,
    );
    if (field.geojson.features.length === 0) throw new Error("unreadable model values");
    map.getSource("current-field")?.setData(field.geojson);
    const centre = {
      longitude: (bounds.west + bounds.east) / 2,
      latitude: (bounds.south + bounds.north) / 2,
    };
    const centreIndex = points.reduce((nearest, point, index) => {
      const distance = Math.hypot(point.longitude - centre.longitude, point.latitude - centre.latitude);
      return distance < nearest.distance ? { index, distance } : nearest;
    }, { index: 0, distance: Infinity }).index;
    const centreSample = sampleMarineAt(Array.isArray(data) ? data[centreIndex] : data, start);
    marineDepthContext = Number.isFinite(centreSample?.seaLevelMsl)
      ? { point: centre, seaLevelMsl: centreSample.seaLevelMsl, validTime: centreSample.validTime }
      : null;
    refreshDepthAdjustment();
    const routeTimed = field.samples.filter((sample) => sample.forecastWeight > 0.01).length;
    elements.currentStatus.textContent = `${field.samples.length} model samples on a ${dimensions.columns}×${dimensions.rows} zoom-adaptive grid · teal is current time; ${routeTimed} samples blend through blue to purple at the nearest expected route time within 8 NM. Arrows point with the flow; labels show knots.`;
  } catch (error) {
    if (error.name === "AbortError") return;
    map.getSource("current-field")?.setData(EMPTY_FEATURE_COLLECTION);
    marineDepthContext = null;
    currentDepthAdjustment = null;
    syncAdjustedContourData();
    elements.currentStatus.textContent = `Current and sea-level model unavailable (${error.message}).`;
    elements.tideDepthStatus.textContent = "Contours are shown at their source datum without a time adjustment.";
  }
}

async function updateRouteCurrentEstimate() {
  if (!mapReady || !elements.currentVisible.checked) return;
  if (stops.length < 2) {
    invalidateRouteCurrentEstimate();
    renderSummary();
    return;
  }
  const start = selectedStartTime();
  const boatSpeed = Number(elements.speedKnots.value);
  const summary = passageSummary(stops, boatSpeed);
  if (!start || !Number.isFinite(summary.durationSeconds)) return;
  if (summary.durationSeconds > 7 * 24 * 60 * 60) {
    invalidateRouteCurrentEstimate();
    elements.stillWaterDuration.textContent = "Passage exceeds the marine model forecast window.";
    return;
  }

  routeCurrentAbortController?.abort();
  routeCurrentAbortController = new AbortController();
  const requestSequence = ++routeCurrentRequestSequence;
  const samplePlan = routeSamplePlan(summary);
  const points = samplePlan.map((sample) => sample.point);
  const rangeSeconds = Math.min(
    8 * 24 * 60 * 60,
    Math.max(6 * 60 * 60, summary.durationSeconds * 2),
  );
  elements.stillWaterDuration.textContent = "Loading currents expected along the passage…";
  try {
    const response = await fetch(
      marineRequestUrl(points, start, new Date(start.getTime() + rangeSeconds * 1000)),
      {
        headers: { Accept: "application/json" },
        signal: routeCurrentAbortController.signal,
      },
    );
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    if (requestSequence !== routeCurrentRequestSequence) return;
    routeCurrentEstimate = estimatePassageWithCurrents(
      summary,
      data,
      start,
      boatSpeed,
      samplePlan,
    );
    map.getSource("route-current")?.setData(
      routeCurrentGeoJson(routeCurrentEstimate, currentRouteArrowLength()),
    );
    renderSummary();
    updateCurrentField();
    if (!routeCurrentEstimate?.complete) {
      elements.stillWaterDuration.textContent = "Some leg currents were unavailable; showing still-water passage time.";
    }
  } catch (error) {
    if (error.name === "AbortError") return;
    routeCurrentEstimate = null;
    map.getSource("route-current")?.setData(EMPTY_FEATURE_COLLECTION);
    renderSummary();
    elements.stillWaterDuration.textContent = `Still-water time; route current unavailable (${error.message}).`;
  }
}

function showCurrentPopup(position, properties) {
  const speed = Number(properties.speedKnots);
  const direction = Number(properties.directionTowards);
  const seaLevel = Number(properties.seaLevelMsl);
  const courseToSteer = properties.kind?.startsWith("course-to-steer");
  const container = document.createElement("div");
  container.className = "marine-popup current-popup";
  const heading = document.createElement("h3");
  heading.textContent = courseToSteer
    ? `Course to steer ${String(Math.round(Number(properties.headingDegrees))).padStart(3, "0")}°T`
    : `${speed.toFixed(1)} kn towards ${String(Math.round(direction)).padStart(3, "0")}°T`;
  const detail = document.createElement("p");
  detail.textContent = courseToSteer
    ? `To maintain ${String(Math.round(Number(properties.trackBearingDegrees))).padStart(3, "0")}°T over ground near leg ${properties.legIndex}, using ${speed.toFixed(1)} kn current towards ${String(Math.round(direction)).padStart(3, "0")}°T at ${formatPassageTime(new Date(properties.validTime))}.`
    : properties.timing === "current"
      ? `Model field at current time ${formatPassageTime(new Date(properties.validTime))}`
      : `Model field blended towards the nearest expected route time: ${formatPassageTime(new Date(properties.validTime))}`;
  const level = document.createElement("p");
  level.textContent = Number.isFinite(seaLevel)
    ? `Model sea level ${formatSignedMetres(seaLevel)} relative to MSL.`
    : "Model sea level unavailable at this point.";
  const warning = document.createElement("p");
  warning.textContent = courseToSteer
    ? "Planning estimate from a coarse ocean model. It is not a helm instruction; verify against official tidal and pilotage information."
    : "Open-Meteo ocean model, about 8 km resolution. Not a tidal atlas or coastal-navigation source.";
  container.append(heading, detail, level, warning);
  new maplibregl.Popup({ offset: 10, closeButton: true })
    .setLngLat(position)
    .setDOMContent(container)
    .addTo(map);
}

function scheduleMarineRefresh({ field = false, route = false } = {}, delay = 350) {
  marineRefreshPending.field ||= field;
  marineRefreshPending.route ||= route;
  clearTimeout(marineRefreshTimer);
  marineRefreshTimer = setTimeout(() => {
    const pending = marineRefreshPending;
    marineRefreshPending = { field: false, route: false };
    if (pending.field) updateCurrentField();
    if (pending.route) updateRouteCurrentEstimate();
  }, delay);
}

function invalidateRouteCurrentEstimate() {
  routeCurrentAbortController?.abort();
  routeCurrentRequestSequence += 1;
  routeCurrentEstimate = null;
  map.getSource("route-current")?.setData(EMPTY_FEATURE_COLLECTION);
}

function currentRouteArrowLength() {
  const bounds = visibleMapBounds();
  const canvas = map.getCanvas();
  const dimensions = currentGridDimensions(canvas.clientWidth, canvas.clientHeight, map.getZoom());
  return Math.max(
    0.00008,
    Math.min(
      (bounds.north - bounds.south) / dimensions.rows,
      (bounds.east - bounds.west) / dimensions.columns,
    ) * 0.34,
  );
}

function refreshDepthAdjustment() {
  currentDepthAdjustment = marineDepthContext
    ? depthAdjustmentFor({ provider: shallowContourProvider, ...marineDepthContext })
    : null;
  syncAdjustedContourData();
  if (!marineDepthContext) {
    elements.tideDepthStatus.textContent = "Contours are shown at their source datum without a time adjustment.";
  } else if (!currentDepthAdjustment && shallowContourProvider === "emodnet") {
    elements.tideDepthStatus.textContent = "EMODnet contours remain at LAT: no nearby bundled LAT↔MSL datum transform is available for this map area.";
  } else if (currentDepthAdjustment) {
    const station = currentDepthAdjustment.stationName
      ? ` using the ${currentDepthAdjustment.stationName} datum transform`
      : "";
    elements.tideDepthStatus.textContent = `Contour labels add ${formatSignedMetres(currentDepthAdjustment.heightM)} model water level above ${currentDepthAdjustment.chartDatum}${station}, at the passage start. This is not under-keel clearance.`;
  }
}

function syncAdjustedContourData() {
  if (!mapReady) return;
  const data = currentDepthAdjustment
    ? {
        ...shallowContourData,
        features: shallowContourData.features.map((feature) => {
          const adjustedDepth = Number(feature.properties?.depthM) + currentDepthAdjustment.heightM;
          return {
            ...feature,
            properties: {
              ...feature.properties,
              adjustedDepthM: adjustedDepth,
              displayLabel: `${feature.properties.depthM} m ${currentDepthAdjustment.chartDatum} → ~${adjustedDepth.toFixed(1)} m`,
              tideHeightM: currentDepthAdjustment.heightM,
              tideValidTime: marineDepthContext?.validTime,
            },
          };
        }),
      }
    : shallowContourData;
  map.getSource("shallow-contours")?.setData(data);
}

async function updateShallowContours(force = false) {
  if (!mapReady || !elements.shallowContoursVisible.checked) return;
  const visibleBounds = visibleMapBounds();
  const useEmodnet = boundsContain(EMODNET_COVERAGE, visibleBounds);
  const provider = useEmodnet ? "emodnet" : "gebco";
  const request = useEmodnet
    ? createContourRequest(visibleBounds, map.getZoom())
    : createGebcoContourRequest(visibleBounds, map.getZoom());
  if (!request) {
    elements.shallowContourStatus.textContent = map.getZoom() < 8
      ? "Zoom in to level 8 or closer to derive shallow contours for the visible coast."
      : "Global contours cannot be sampled while this view crosses the 180° meridian.";
    shallowContourBounds = null;
    shallowContourProvider = null;
    shallowContourData = EMPTY_FEATURE_COLLECTION;
    refreshDepthAdjustment();
    return;
  }
  if (
    !force &&
    shallowContourProvider === provider &&
    boundsContain(shallowContourBounds, visibleBounds)
  ) {
    return;
  }

  shallowContourAbortController?.abort();
  shallowContourAbortController = new AbortController();
  const controller = shallowContourAbortController;
  elements.shallowContourStatus.textContent = provider === "emodnet"
    ? "Loading higher-resolution EMODnet depths for this map area…"
    : "Loading the global GEBCO grid and deriving contours for this map area…";
  try {
    const response = await fetch(request.url, {
      headers: { Accept: "text/plain" },
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const responseText = await response.text();
    const parsed = provider === "emodnet"
      ? parseEmodnetGrid(responseText)
      : parseGebcoGrid(responseText);
    if (controller !== shallowContourAbortController) return;
    shallowContourData = deriveShallowContours(
      parsed,
      undefined,
      provider === "emodnet"
        ? {}
        : {
            featurePrefix: "gebco-live",
            sourceName: "GEBCO 2026 Grid",
            warning:
              "Coarse global model-derived contour; not a charted sounding or safe clearance.",
          },
    );
    shallowContourBounds = request.bounds;
    shallowContourProvider = provider;
    refreshDepthAdjustment();
    const resolution = request.resolutionLimited
      ? "regional preview resolution; zoom closer for more detail"
      : "native model resolution";
    const source = provider === "emodnet" ? "EMODnet" : "GEBCO global fallback";
    elements.shallowContourStatus.textContent = `${shallowContourData.features.length.toLocaleString("en-GB")} ${source} lines for this area · ${resolution} · coastal land/sea transition cells omitted.`;
  } catch (error) {
    if (error.name === "AbortError") return;
    elements.shallowContourStatus.textContent = `Contours unavailable for this area (${error.message}).`;
  }
}

function visibleMapBounds() {
  const bounds = map.getBounds();
  return {
    west: bounds.getWest(),
    south: bounds.getSouth(),
    east: bounds.getEast(),
    north: bounds.getNorth(),
  };
}

function fitPassage() {
  if (!mapReady || stops.length === 0) return;
  if (stops.length === 1) {
    map.easeTo({ center: [stops[0].longitude, stops[0].latitude], zoom: 13 });
    return;
  }
  const bounds = stops.reduce(
    (value, stop) => value.extend([stop.longitude, stop.latitude]),
    new maplibregl.LngLatBounds(),
  );
  map.fitBounds(bounds, { padding: 70, maxZoom: 13 });
}

function scheduleDraftSave() {
  clearTimeout(draftSaveTimer);
  draftSaveTimer = setTimeout(() => {
    try {
      localStorage.setItem(PLANNER_DRAFT_KEY, encodePlannerDraft({
        passageName: elements.passageName.value,
        speedKnots: Number(elements.speedKnots.value),
        startTime: selectedStartTime()?.toISOString() ?? null,
        stops,
        bathymetrySource: elements.bathymetryVisible.checked
          ? "emodnet"
          : elements.gebcoVisible.checked ? "gebco" : "none",
        bathymetryVisible: elements.bathymetryVisible.checked,
        gebcoVisible: elements.gebcoVisible.checked,
        depthPalette: elements.depthPalette.value,
        shallowContoursVisible: elements.shallowContoursVisible.checked,
        offshoreContoursVisible: elements.offshoreContoursVisible.checked,
        noaaVisible: elements.noaaVisible.checked,
        seamarksVisible: elements.seamarksVisible.checked,
        windVisible: elements.windVisible.checked,
        currentVisible: elements.currentVisible.checked,
        poiCategories: selectedCategories(),
      }));
      elements.draftStatus.textContent = "Saved on this device only.";
    } catch {
      elements.draftStatus.textContent = "This browser could not save the planner draft.";
    }
  }, 250);
}

function restoreDraft() {
  let draft = null;
  try {
    draft = decodePlannerDraft(localStorage.getItem(PLANNER_DRAFT_KEY));
  } catch {
    return;
  }
  if (!draft) {
    elements.startTime.value = defaultStartTimeValue();
    for (const input of elements.poiFilters.querySelectorAll('input[type="checkbox"]')) {
      input.checked = DEFAULT_CATEGORIES.includes(input.value);
    }
    return;
  }
  stops = draft.stops;
  stopSequence = stops.reduce((maximum, stop) => Math.max(maximum, stop.id), 0);
  elements.passageName.value = draft.passageName;
  elements.speedKnots.value = String(draft.speedKnots);
  elements.startTime.value = draft.startTime
    ? localDateTimeValue(new Date(draft.startTime))
    : defaultStartTimeValue();
  elements.bathymetryVisible.checked = draft.bathymetryVisible;
  elements.gebcoVisible.checked = draft.gebcoVisible;
  elements.depthPalette.value = draft.depthPalette;
  elements.shallowContoursVisible.checked = draft.shallowContoursVisible;
  elements.offshoreContoursVisible.checked = draft.offshoreContoursVisible;
  elements.noaaVisible.checked = draft.noaaVisible;
  elements.seamarksVisible.checked = draft.seamarksVisible;
  elements.windVisible.checked = draft.windVisible;
  elements.currentVisible.checked = draft.currentVisible;
  const savedCategories = new Set(draft.poiCategories.length > 0 ? draft.poiCategories : DEFAULT_CATEGORIES);
  for (const input of elements.poiFilters.querySelectorAll('input[type="checkbox"]')) {
    input.checked = savedCategories.has(input.value);
  }
  elements.draftStatus.textContent = "Restored from this device.";
}

function formatExpiry(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "at the time shown in the app" : date.toLocaleDateString("en-GB");
}

function currentTheme() {
  return document.documentElement.dataset.theme === "dark" ? "dark" : "light";
}

function selectedStartTime() {
  const date = new Date(elements.startTime.value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function defaultStartTimeValue(now = new Date()) {
  const rounded = new Date(Math.ceil(now.getTime() / 900_000) * 900_000);
  return localDateTimeValue(rounded);
}

function localDateTimeValue(date) {
  const pad = (value) => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function formatPassageTime(date) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("en-GB", {
    weekday: "short",
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function formatSignedKnots(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return "—";
  return `${number >= 0 ? "+" : "−"}${Math.abs(number).toFixed(1)} kn`;
}

function formatSignedMetres(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return "—";
  return `${number >= 0 ? "+" : "−"}${Math.abs(number).toFixed(2)} m`;
}
