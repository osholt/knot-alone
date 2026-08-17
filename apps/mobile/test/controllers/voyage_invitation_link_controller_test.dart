import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_invitation_link_controller.dart';
import 'package:tide_and_seek/services/voyage_invitation_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cold-start invitation is pulled and validated', () async {
    final source = _QueuedSource([
      voyageInvitationUrl('123456', 'Abcdefghijklmnop12345678'),
    ]);
    final controller = await VoyageInvitationLinkController.load(
      source: source,
    );

    expect(controller.pending?.voyageCode, '123456');
    expect(controller.pending?.joinToken, 'Abcdefghijklmnop12345678');
    expect(controller.errorMessage, isNull);

    controller.dispose();
  });

  test(
    'warm refresh replaces a malformed notice with a later valid link',
    () async {
      final source = _QueuedSource([
        'https://tideandseek.invalid/join.html#bad',
      ]);
      final controller = await VoyageInvitationLinkController.load(
        source: source,
      );

      expect(controller.pending, isNull);
      expect(controller.errorMessage, contains('malformed'));

      source.values.add(
        voyageInvitationUrl('654321', 'ZYXWVUTSRQPONMLK12345678'),
      );
      await controller.refresh();

      expect(controller.pending?.voyageCode, '654321');
      expect(controller.errorMessage, isNull);

      controller.dispose();
    },
  );
}

class _QueuedSource implements IncomingVoyageInvitationLinkSource {
  _QueuedSource(Iterable<String> initial) : values = [...initial];

  final List<String> values;

  @override
  Future<String?> consumePending() async =>
      values.isEmpty ? null : values.removeAt(0);
}
