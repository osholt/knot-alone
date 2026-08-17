import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/services/skipper_track_exemption.dart';

void main() {
  final skipperTrack = [
    for (var index = 0; index <= 10; index += 1)
      GeoPoint(latitude: 52, longitude: -1 + index * 0.01),
  ];

  test('a sailor inside the corridor is following the skipper', () {
    expect(
      SkipperTrackExemption.isFollowingSkipperTrack(
        position: const GeoPoint(latitude: 52.0005, longitude: -0.95),
        skipperTrack: skipperTrack,
      ),
      isTrue,
    );
  });

  test('a sailor outside the corridor is not', () {
    expect(
      SkipperTrackExemption.isFollowingSkipperTrack(
        position: const GeoPoint(latitude: 52.01, longitude: -0.95),
        skipperTrack: skipperTrack,
      ),
      isFalse,
    );
  });

  test('an uncertain fix gets the benefit of its own accuracy', () {
    const justOutside = GeoPoint(latitude: 52.0015, longitude: -0.95);
    expect(
      SkipperTrackExemption.isFollowingSkipperTrack(
        position: justOutside,
        skipperTrack: skipperTrack,
      ),
      isFalse,
    );
    expect(
      SkipperTrackExemption.isFollowingSkipperTrack(
        position: justOutside,
        skipperTrack: skipperTrack,
        accuracyMeters: 75,
      ),
      isTrue,
    );
  });

  test('a skipper with no track yet exempts nobody', () {
    expect(
      SkipperTrackExemption.isFollowingSkipperTrack(
        position: const GeoPoint(latitude: 52, longitude: -1),
        skipperTrack: const [GeoPoint(latitude: 52, longitude: -1)],
      ),
      isFalse,
    );
  });
}
