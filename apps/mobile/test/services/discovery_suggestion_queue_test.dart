import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/discovery_suggestion_queue.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps an unsubmitted discovery suggestion offline', () async {
    SharedPreferences.setMockInitialValues({});
    final queue = await DiscoverySuggestionQueue.openDefault();
    await queue.enqueue(
      category: MotorcycleDiscoveryCategory.mountainPass,
      action: 'add',
      name: 'Test pass',
      reason: 'Signed summit on an open public road',
      point: const GeoPoint(latitude: 52, longitude: -3.1),
    );
    final reopened = await DiscoverySuggestionQueue.openDefault();
    expect(reopened.drafts, hasLength(1));
    expect(reopened.drafts.single.name, 'Test pass');

    final preferences = await SharedPreferences.getInstance();
    final stored =
        jsonDecode(
              preferences.getString('ride-relay-discovery-suggestions-v1')!,
            )
            as List;
    expect(stored.single['geometry']['type'], 'Point');
  });
}
