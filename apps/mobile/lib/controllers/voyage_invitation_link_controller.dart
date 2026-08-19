import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/voyage_invitation_link.dart';

/// Holds one OS-delivered voyage invitation until the app can present it safely.
///
/// Native code owns cold/warm URL capture; this controller owns lifecycle pulls
/// and validation. Joining remains a deliberate UI action because replacing an
/// active voyage silently would lose safety state.
class VoyageInvitationLinkController extends ChangeNotifier
    with WidgetsBindingObserver {
  VoyageInvitationLinkController._(this._source) {
    WidgetsBinding.instance.addObserver(this);
  }

  final IncomingVoyageInvitationLinkSource _source;
  VoyageInvitationLink? _pending;
  String? _errorMessage;
  Future<void>? _refreshOperation;

  VoyageInvitationLink? get pending => _pending;
  String? get errorMessage => _errorMessage;
  bool get hasNotice => _pending != null || _errorMessage != null;

  static Future<VoyageInvitationLinkController> load({
    IncomingVoyageInvitationLinkSource source =
        const VoyageInvitationLinkChannel(),
  }) async {
    final controller = VoyageInvitationLinkController._(source);
    await controller.refresh();
    return controller;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh() {
    final existing = _refreshOperation;
    if (existing != null) return existing;
    final operation = _performRefresh();
    _refreshOperation = operation;
    return operation.whenComplete(() {
      if (identical(_refreshOperation, operation)) _refreshOperation = null;
    });
  }

  Future<void> _performRefresh() async {
    final rawLink = await _source.consumePending();
    if (rawLink == null) return;
    final invitation = voyageInvitationFromLink(rawLink);
    if (invitation == null) {
      _pending = null;
      _errorMessage =
          'That voyage invitation is incomplete or malformed. Ask the skipper to share it again.';
    } else {
      _pending = invitation;
      _errorMessage = null;
    }
    notifyListeners();
  }

  void clear() {
    if (!hasNotice) return;
    _pending = null;
    _errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
