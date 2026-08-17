import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/services/voyage_diagnostics_configuration.dart';

/// The define-**off** half of the voyage-diagnostics coverage, following the shape
/// `test_control_server_test.dart` established: the default suite runs without the
/// define, exactly as CI and a release build do.
void main() {
  group(
    'an ordinary build records nothing',
    () {
      // The recorder writes down where a sailor went. `enabled` is a `const` read of
      // the environment so a build without the define tree-shakes it out — the code
      // is not there to be switched on. If this fails, a store build carries a
      // location recorder.
      test('the recorder is not compiled in', () {
        expect(VoyageDiagnosticsConfiguration.enabled, isFalse);
      });
    },
    // Skipped in an instrumented build. A named reason so a skipped run says
    // why, following test_control_server_test.dart.
    skip: VoyageDiagnosticsConfiguration.enabled
        ? 'asserts the define-off build; run without TIDE_AND_SEEK_RIDE_DIAGNOSTICS'
        : null,
  );

  group('bounds that hold whichever way the build was compiled', () {
    test('the entry bound is finite, so a long voyage cannot grow it', () {
      expect(VoyageDiagnosticsConfiguration.maximumEntries, greaterThan(0));
      expect(
        VoyageDiagnosticsConfiguration.maximumEntries,
        lessThanOrEqualTo(20000),
        reason: 'the phone is also running navigation',
      );
    });

    test('the heading sample sits outside the junction, with slack', () {
      // Sampled far enough from the junction that the sailor is on the road
      // rather than in it, and the tolerance must not be so wide that a sample
      // from inside the junction can satisfy it.
      expect(
        VoyageDiagnosticsConfiguration.headingSampleMeters,
        greaterThan(20),
      );
      expect(
        VoyageDiagnosticsConfiguration.headingSampleToleranceMeters,
        lessThan(VoyageDiagnosticsConfiguration.headingSampleMeters),
      );
    });
  });
}
