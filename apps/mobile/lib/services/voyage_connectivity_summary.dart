import 'package:meta/meta.dart';

/// How well the group can see this sailor, in one answer.
///
/// The voyage dashboard carried three independent connectivity cards, each
/// accurate and jointly useless. A tester photographed all three at once:
/// `Searching nearby · 106 queued`, a green **Server sync succeeded**, and an
/// amber **Live sailor positions are paused because the voyage service cannot be
/// reached** (#174). Both of the last two were true - the event batch had synced
/// and the presence channel was down - and a sailor cannot act on a screen that
/// says yes and no about the same thing.
///
/// So the channels keep their own cards, and this decides the one line above
/// them. The question it answers is the only one a sailor is really asking: *is
/// the group seeing where I am?*
enum VoyageConnectivityState {
  /// Positions are flowing and the journal is current.
  reaching,

  /// Working, but with something outstanding worth naming - a queue that has not
  /// drained, or a sync old enough to stop trusting.
  degraded,

  /// The group is not seeing this sailor's position.
  notReaching,

  /// No transport is configured or running, so there is nothing to report.
  inactive,
}

@immutable
class VoyageConnectivitySummary {
  const VoyageConnectivitySummary({
    required this.state,
    required this.headline,
    required this.detail,
  });

  final VoyageConnectivityState state;

  /// The answer, in the sailor's terms rather than the transport's.
  final String headline;

  /// Why, and what will happen next. Never a bare number.
  final String detail;

  /// A sync older than this stops counting as success.
  ///
  /// 90 seconds, matching `RouteDeviationConfig.coordinatorStaleAfter`, so
  /// "stale" means the same length of time here as it does when the app decides
  /// a sailor's position can no longer be trusted.
  static const staleSyncAfter = Duration(seconds: 90);

  /// [positionsPaused] is the presence channel's own verdict, and it wins.
  /// Whatever the event batch managed, a sailor whose positions are paused is a
  /// sailor the group cannot see moving.
  ///
  /// [queuedEventCount] is the journal backlog waiting to upload. It is reported
  /// with what will happen to it rather than as a number the sailor has to
  /// interpret - `106 queued` told the tester nothing about whether that was
  /// normal.
  factory VoyageConnectivitySummary.from({
    required bool transportActive,
    required bool positionsPaused,
    required int queuedEventCount,
    required DateTime? lastSuccessfulSync,
    required DateTime now,
  }) {
    final queue = _queueSentence(queuedEventCount);
    if (!transportActive) {
      return VoyageConnectivitySummary(
        state: VoyageConnectivityState.inactive,
        headline: 'Not sharing your position',
        detail: queuedEventCount == 0
            ? 'No voyage service is connected on this phone.'
            : 'No voyage service is connected on this phone. $queue',
      );
    }
    if (positionsPaused) {
      return VoyageConnectivitySummary(
        state: VoyageConnectivityState.notReaching,
        headline: 'The group cannot see where you are',
        detail: queuedEventCount == 0
            ? 'Live positions are paused. They resume on their own once the '
                  'voyage service can be reached.'
            : 'Live positions are paused. They resume on their own once the '
                  'voyage service can be reached. $queue',
      );
    }
    final staleSince = lastSuccessfulSync == null
        ? null
        : now.difference(lastSuccessfulSync);
    if (staleSince == null) {
      return VoyageConnectivitySummary(
        state: VoyageConnectivityState.degraded,
        headline: 'Reaching the group, but not just now',
        detail:
            'Nothing has reached the voyage service yet on this voyage. $queue',
      );
    }
    if (staleSince >= staleSyncAfter) {
      return VoyageConnectivitySummary(
        state: VoyageConnectivityState.degraded,
        headline: 'Reaching the group, but not just now',
        detail:
            'The last exchange with the voyage service was '
            '${_ago(staleSince)} ago. $queue',
      );
    }
    if (queuedEventCount > 0) {
      return VoyageConnectivitySummary(
        state: VoyageConnectivityState.degraded,
        headline: 'Reaching the group',
        detail: queue,
      );
    }
    return const VoyageConnectivitySummary(
      state: VoyageConnectivityState.reaching,
      headline: 'Reaching the group',
      detail: 'Positions and voyage events are up to date.',
    );
  }

  /// What the backlog means, not how big it is.
  ///
  /// A backlog is normal on this design - the journal is the record and the relay
  /// drains it - so the wording says it is going rather than implying a fault.
  static String _queueSentence(int queuedEventCount) {
    if (queuedEventCount == 0) return 'Nothing is waiting to send.';
    if (queuedEventCount == 1) {
      return 'One voyage event is waiting to send, and will go on the next '
          'exchange.';
    }
    return '$queuedEventCount voyage events are waiting to send, and will go on '
        'the next exchanges.';
  }

  static String _ago(Duration elapsed) {
    if (elapsed.inMinutes < 1) return '${elapsed.inSeconds} seconds';
    if (elapsed.inMinutes == 1) return 'a minute';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes} minutes';
    if (elapsed.inHours == 1) return 'an hour';
    return '${elapsed.inHours} hours';
  }
}
