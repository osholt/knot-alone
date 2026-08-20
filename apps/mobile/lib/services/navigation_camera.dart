import 'dart:math' as math;

/// MapLibre's perspective camera uses a fixed vertical field of view of
/// 36.87 degrees on every platform, so the camera sits
/// `0.5 * viewportHeight / tan(fov / 2)` pixels away from the point it is
/// aimed at. The forward-bias geometry below depends on that relationship.
const double _cameraFieldOfViewRadians = 0.6435011087932844;

/// Sailing uses a chart-like plan view. Keeping the pitch at zero avoids hiding
/// nearby water behind a perspective horizon and makes scale consistent in
/// every direction.
const double navigationCameraMaximumTiltDegrees = 0;

/// Retained as a compatibility boundary for projected displays and tests. The
/// sailing plan view no longer changes scale or pitch with speed.
const double navigationCameraFramingTopSpeedMetersPerSecond = 30;

/// Vertical position of the sailor in the map viewport, as a fraction of the
/// viewport height measured from the top edge. A small, stable forward bias
/// leaves room for water ahead without making the framing jump with speed.
const double navigationCameraRestSailorFractionPortrait = 0.58;
const double navigationCameraFastSailorFractionPortrait = 0.58;
const double navigationCameraRestSailorFractionLandscape = 0.58;
const double navigationCameraFastSailorFractionLandscape = 0.58;

/// Legacy names retained for projected-display compatibility. A chart has no
/// traffic side, so both orientations keep the vessel centred horizontally.
const double navigationCameraLandscapeSailorFractionLeftTraffic = 0.5;
const double navigationCameraLandscapeSailorFractionRightTraffic = 0.5;

/// Space kept between the sailor's marker and the top of the bottom chrome
/// band, as a fraction of the viewport height. The marker is 38 logical
/// pixels tall, so this leaves its full height plus a margin clear on an
/// 800 pixel viewport.
const double navigationCameraSailorChromeClearanceFraction = 0.06;

/// How high in the frame the sailor may be pushed when a very tall chrome band
/// would otherwise cover the centre of the viewport. Keeping the marker visible
/// beats keeping the forward bias, so the framing gives up the bias - and, past
/// this point, some of the road behind - rather than hiding the sailor.
const double navigationCameraMinimumSailorFraction = 0.35;

/// The look-ahead the camera is allowed to aim at, whatever the tilt and zoom
/// geometry asks for. A bounded value keeps a mis-measured viewport or an
/// unusually shallow latitude from throwing the camera kilometres up the road.
const double navigationCameraMaximumLookAheadMeters = 1200;

/// How close the map has to be to the framing follow mode asked for before the
/// camera counts as having *arrived* at the navigation viewport.
///
/// This is an arrival test, not a licence to drift. It answers only "has the
/// camera reached the framing this app just commanded", so the sailor is not
/// offered a way back to a viewport the camera is still easing into (#141).
/// Losing the viewport is never decided by distance: it happens when follow mode
/// gives the camera up, which a single pan does immediately.
///
/// Logical pixels rather than metres, because the same ground distance is a
/// whole screen at navigation zoom and a thumbnail at route-overview zoom. 12 px
/// sits above the ~5 px a camera easing after a moving sailor lags by, and far
/// below the tens of pixels of the shortest deliberate pan.
///
/// #133 used 56 px against a *freshly planned* framing rather than against the
/// commanded one. Read off an SE on 26 July 2026, that tolerance was 1363 m of
/// ground at the zoom the map actually sat at, so a map panned 468 m off the
/// sailor still reported itself framed.
const double navigationCameraViewportSettleTolerancePixels = 12;

/// How far the reported zoom may sit from the commanded zoom and still count as
/// arrived. Small on purpose: a route overview and a navigation viewport differ
/// by whole zoom levels, and the point of checking is that an overview can never
/// pass for the viewport.
const double navigationCameraViewportSettleZoomTolerance = 0.08;

/// The navigation viewport the phone has actually commanded.
///
/// Projected displays have a different aspect ratio, so they cannot reproduce
/// the phone pixel-for-pixel. They can, however, use the same ground target,
/// scale, pitch and bearing and compensate only for their viewport height.
/// Publishing the commanded viewport keeps that calculation in one place —
/// [NavigationCameraPlanner] — instead of maintaining a second collection of
/// approximate projected-display camera constants.
class NavigationCameraViewport {
  const NavigationCameraViewport({
    required this.latitude,
    required this.longitude,
    required this.zoom,
    required this.tilt,
    required this.bearing,
    required this.sourceViewportHeightPixels,
    required this.sourceViewportWidthPixels,
    required this.sailorViewportFraction,
    required this.sailorHorizontalViewportFraction,
    required this.leftHandTraffic,
    required this.mapStyleUrl,
    required this.mapStyleJson,
  });

  final double latitude;
  final double longitude;
  final double zoom;
  final double tilt;
  final double bearing;
  final double sourceViewportHeightPixels;
  final double sourceViewportWidthPixels;

  /// Exact phone anchors, projected so a differently shaped screen can
  /// place the sailor deliberately instead of inheriting a coincidental offset.
  final double sailorViewportFraction;
  final double sailorHorizontalViewportFraction;

  /// Route driving side independently of the phone's current orientation.
  /// A projected display is always landscape, even when the phone is portrait.
  final bool leftHandTraffic;

  /// The exact day/night style selected for the phone map.
  final String mapStyleUrl;

  /// The resolved style document the phone is actually rendering.
  ///
  /// This can differ from [mapStyleUrl]: the phone normalises relative tile,
  /// glyph and sprite URLs, can serve a cached copy, and repaints a single
  /// configured style for legible dark mode. Projected displays must use this
  /// resolved document if their tiles are to match the phone exactly.
  final String mapStyleJson;
}

/// A camera framing for one voyage update.
class NavigationCameraPlan {
  const NavigationCameraPlan({
    required this.zoom,
    required this.tilt,
    required this.sailorViewportFraction,
    required this.sailorHorizontalViewportFraction,
    required this.forwardBiasPixels,
    required this.lateralBiasPixels,
    required this.lookAheadMeters,
  });

  final double zoom;
  final double tilt;

  /// Where the sailor's own marker sits vertically in the map viewport, as a
  /// fraction of its height from the top edge. Always at or below the centre.
  final double sailorViewportFraction;

  /// Horizontal position of the sailor from the left edge.
  final double sailorHorizontalViewportFraction;

  /// Logical pixels between the viewport centre and the sailor's marker.
  /// Negative when the marker sits above the centre.
  ///
  /// This is the input to both look-ahead conversions rather than something to
  /// hand a map as a screen-space offset: neither map implementation applies
  /// such an offset reliably, so the bias is always baked into the camera
  /// target. See [lookAheadMeters] and
  /// [NavigationCameraPlanner.flatLookAheadMetersFor].
  final double forwardBiasPixels;

  /// Logical horizontal pixels between the viewport centre and the sailor.
  /// Negative places the sailor left of centre.
  final double lateralBiasPixels;

  /// Ground distance from the sailor to the point the camera is aimed at.
  ///
  /// `maplibre_gl` 0.26 exposes no camera padding or anchor, so the forward
  /// bias is applied by aiming the camera at a point this far ahead along the
  /// current bearing. The distance is derived from the tilt, zoom and viewport
  /// geometry, so the sailor lands at [sailorViewportFraction] by construction
  /// rather than by guessing a look-ahead distance.
  final double lookAheadMeters;
}

/// Plans a stable, top-down sailing chart camera.
///
/// Speed is accepted for API compatibility but deliberately does not change the
/// view. A sailor can zoom and reposition the chart during a voyage; follow mode
/// returns to this predictable wider framing rather than a speed-dependent one.
abstract final class NavigationCameraPlanner {
  static NavigationCameraPlan plan({
    required double? speedMetersPerSecond,
    required bool landscape,
    double viewportHeightPixels = 800,
    double viewportWidthPixels = 400,
    double latitudeDegrees = 51.5,
    double bottomChromeFraction = 0,
    bool leftHandTraffic = true,
  }) {
    final zoom = landscape ? 12.2 : 12.6;
    const tilt = navigationCameraMaximumTiltDegrees;
    final height = viewportHeightPixels.isFinite && viewportHeightPixels > 0
        ? viewportHeightPixels
        : 800.0;
    final width = viewportWidthPixels.isFinite && viewportWidthPixels > 0
        ? viewportWidthPixels
        : 400.0;
    final sailorFraction = _sailorViewportFraction(
      landscape: landscape,
      bottomChromeFraction: bottomChromeFraction,
    );
    final forwardBiasPixels = (sailorFraction - 0.5) * height;
    const horizontalFraction = 0.5;
    final lateralBiasPixels = (horizontalFraction - 0.5) * width;
    return NavigationCameraPlan(
      zoom: zoom,
      tilt: tilt,
      sailorViewportFraction: sailorFraction,
      sailorHorizontalViewportFraction: horizontalFraction,
      forwardBiasPixels: forwardBiasPixels,
      lateralBiasPixels: lateralBiasPixels,
      lookAheadMeters: lookAheadMetersFor(
        tiltDegrees: tilt,
        zoom: zoom,
        forwardBiasPixels: forwardBiasPixels,
        viewportHeightPixels: height,
        latitudeDegrees: latitudeDegrees,
      ),
    );
  }

  /// The sailor's vertical position, biased forward with speed and then pulled
  /// back far enough to keep the marker clear of the bottom chrome band.
  ///
  /// [bottomChromeFraction] is the share of the viewport height occupied by
  /// overlays directly below the sailor. Portrait chrome sits in a bottom band
  /// under the marker, so it constrains the bias; landscape chrome lives in
  /// side rails that the centred marker never reaches, so callers pass zero.
  static double _sailorViewportFraction({
    required bool landscape,
    required double bottomChromeFraction,
  }) {
    final rest = landscape
        ? navigationCameraRestSailorFractionLandscape
        : navigationCameraRestSailorFractionPortrait;
    final preferred = rest;
    final chrome = bottomChromeFraction.isFinite
        ? bottomChromeFraction.clamp(0.0, 1.0)
        : 0.0;
    final allowed = 1 - chrome - navigationCameraSailorChromeClearanceFraction;
    return math.max(
      navigationCameraMinimumSailorFraction,
      math.min(preferred, allowed),
    );
  }

  /// Ground distance from the sailor to the camera target that places the sailor
  /// [forwardBiasPixels] below the viewport centre. Negative when the bias is
  /// negative, which only happens when a very tall chrome band has pushed the
  /// marker above the centre of the frame.
  ///
  /// The camera sits `d = 0.5 * height / tan(fov / 2)` pixels from the target
  /// at a pitch of `tilt` from the nadir, so its height above the ground plane
  /// is `d * cos(tilt)`. A screen point [forwardBiasPixels] below the centre is
  /// seen along a ray `atan(bias / d)` shallower than the centre ray, so the
  /// ground distance between the two is
  /// `d * cos(tilt) * (tan(tilt) - tan(tilt - rayAngle))` in ground pixels,
  /// which the Web Mercator scale converts to metres.
  static double lookAheadMetersFor({
    required double tiltDegrees,
    required double zoom,
    required double forwardBiasPixels,
    required double viewportHeightPixels,
    required double latitudeDegrees,
  }) {
    if (forwardBiasPixels == 0 ||
        viewportHeightPixels <= 0 ||
        !forwardBiasPixels.isFinite ||
        !viewportHeightPixels.isFinite) {
      return 0;
    }
    final cameraToCentrePixels =
        0.5 * viewportHeightPixels / math.tan(_cameraFieldOfViewRadians / 2);
    final tilt = tiltDegrees * math.pi / 180;
    final rayAngle = math.atan(forwardBiasPixels / cameraToCentrePixels);
    final groundPixels =
        cameraToCentrePixels *
        math.cos(tilt) *
        (math.tan(tilt) - math.tan(tilt - rayAngle));
    final metres = groundPixels * _metersPerPixel(zoom, latitudeDegrees);
    if (!metres.isFinite) return 0;
    return metres.clamp(
      -navigationCameraMaximumLookAheadMeters,
      navigationCameraMaximumLookAheadMeters,
    );
  }

  /// Ground distance from the sailor to the camera target for a flat, untilted
  /// map.
  ///
  /// `flutter_map` is 2D, so the bias is a straight ground offset at the map's
  /// own scale rather than the perspective geometry [lookAheadMetersFor]
  /// solves. It has to be baked into the camera target: passing it as
  /// `moveAndRotateAnimatedRaw`'s screen-space `offset` does not survive, since
  /// that method delegates to `moveAnimatedRaw` *without* forwarding the offset
  /// whenever the new bearing equals the current one — which the rotation
  /// deadband makes the common case. The camera would then flip between biased
  /// and centred framing as the bearing came in and out of the deadband.
  static double flatLookAheadMetersFor({
    required double zoom,
    required double forwardBiasPixels,
    required double latitudeDegrees,
  }) {
    if (forwardBiasPixels == 0 || !forwardBiasPixels.isFinite) return 0;
    final metres =
        forwardBiasPixels *
        _metersPerPixel(zoom, latitudeDegrees, tileSize: 256);
    if (!metres.isFinite) return 0;
    return metres.clamp(
      -navigationCameraMaximumLookAheadMeters,
      navigationCameraMaximumLookAheadMeters,
    );
  }

  /// Lateral ground offset from the sailor to the camera target.
  ///
  /// A sailor left of centre needs the camera target to their right, hence the
  /// inverted sign. [tileSize] keeps MapLibre (512) and FlutterMap (256) at the
  /// same requested viewport fraction despite their different zoom schemes.
  static double lateralTargetOffsetMetersFor({
    required double zoom,
    required double lateralBiasPixels,
    required double latitudeDegrees,
    required int tileSize,
  }) {
    if (lateralBiasPixels == 0 || !lateralBiasPixels.isFinite) return 0;
    final metres =
        -lateralBiasPixels *
        _metersPerPixel(zoom, latitudeDegrees, tileSize: tileSize);
    if (!metres.isFinite) return 0;
    return metres.clamp(
      -navigationCameraMaximumLookAheadMeters,
      navigationCameraMaximumLookAheadMeters,
    );
  }

  /// Whether a camera reported [driftMeters] and [zoomDelta] away from the
  /// framing this app commanded has arrived at that framing.
  ///
  /// The question "Follow me" asks is whether the camera *is* the navigation
  /// viewport - following the sailor icon at the planned scale - not whether the
  /// sailor happens to be somewhere in frame. #125 asked
  /// instead whether a pan had interrupted an active follow, and follow mode
  /// needs movement, so a phone on a desk was never following and the button
  /// never appeared (#133). #133 asked whether the sailor was roughly in frame,
  /// which a route overview satisfies by accident (#141).
  ///
  /// Both parts matter. Comparing against the commanded framing rather than a
  /// freshly planned one means the answer cannot be satisfied by a camera the app
  /// never drove, and requiring the zoom to match means an overview cannot pass
  /// for a viewport.
  ///
  /// [tileSize] is the renderer's tile scheme, since the same zoom number means
  /// a different scale on each: 512 for MapLibre, 256 for `flutter_map`.
  static bool settledOnViewport({
    required double driftMeters,
    required double zoomDelta,
    required double zoom,
    required double latitudeDegrees,
    required int tileSize,
  }) {
    if (!driftMeters.isFinite || !zoom.isFinite || !zoomDelta.isFinite) {
      return false;
    }
    if (zoomDelta.abs() > navigationCameraViewportSettleZoomTolerance) {
      return false;
    }
    final tolerance =
        navigationCameraViewportSettleTolerancePixels *
        _metersPerPixel(zoom, latitudeDegrees, tileSize: tileSize);
    return tolerance.isFinite && driftMeters.abs() <= tolerance;
  }

  /// Ground metres per logical pixel. MapLibre uses a 512 pixel tile scheme,
  /// `flutter_map` a 256 pixel one, so the same zoom number is a different
  /// scale on each.
  static double _metersPerPixel(
    double zoom,
    double latitudeDegrees, {
    int tileSize = 512,
  }) =>
      (tileSize == 256 ? 156543.03392 : 78271.5169) *
      math.cos(latitudeDegrees * math.pi / 180).abs() /
      math.pow(2, zoom);
}
