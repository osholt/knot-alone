/// Everything needed to join a voyage, carried directly rather than looked up.
///
/// This is what makes an offline join possible at all (#279). Every existing join
/// path - typed code or pasted invite - ends in `VoyageCodeDirectory.resolve`, an
/// HTTPS call to the relay whose entire job is turning a six-digit code into
/// `{voyageId, inviteSecret, resolveToken}`. So a group standing in a car park with
/// no signal cannot form a voyage at all, which is precisely the situation this
/// product exists for.
///
/// A QR code has room for all three, so scanning one needs no network.
///
/// ## Why not a URL
///
/// A URL would spend bytes on a scheme and host to no purpose, and would invite
/// the secret into a path or query where web-server logs and browser history can
/// see it. Making an invitation *tappable* is a separate job with its own
/// constraints (#275); this is a machine-readable payload for a camera, and is
/// deliberately not something a browser will do anything with.
///
/// ## What it exposes
///
/// The voyage's invite secret, in the clear. Anyone who photographs a displayed code
/// can join the voyage. That is the same exposure as a shared invite link and is
/// acceptable for a private group, but it is the reason a display of this must be
/// deliberate and short-lived rather than a screen left sitting open.
class VoyageJoinPayload {
  const VoyageJoinPayload({
    required this.voyageId,
    required this.voyageCode,
    required this.inviteSecret,
    required this.joinToken,
  });

  /// Version prefix, so a payload from a future format is **rejected** rather
  /// than half-understood. A wrong join is worse than a refused one: a sailor who
  /// silently ends up in a degraded session has no way to tell.
  static const scheme = 'sweeper1';

  /// Colon-separated because none of the four fields can contain a colon: the
  /// code is six digits, the id is a UUID, and both secrets are base64url, whose
  /// alphabet is `A-Za-z0-9-_`. So splitting cannot be ambiguous, and no escaping
  /// is needed to keep the payload short.
  static const _separator = ':';

  final String voyageId;
  final String voyageCode;
  final String inviteSecret;
  final String joinToken;

  String encode() =>
      [scheme, voyageCode, voyageId, inviteSecret, joinToken].join(_separator);

  /// Parses [raw], or throws [FormatException] with a reason a person can act on.
  ///
  /// The bounds mirror what the relay itself enforces when it serves these fields,
  /// so a payload this accepts is one the rest of the app can already handle. They
  /// are checked here rather than trusted because a QR code is arbitrary input
  /// from a camera - anyone can print one.
  static VoyageJoinPayload decode(String raw) {
    final parts = raw.trim().split(_separator);
    if (parts.length != 5 || parts.first != scheme) {
      throw const FormatException(
        'That code is not a Tide and Seek voyage invitation.',
      );
    }
    final [_, voyageCode, voyageId, inviteSecret, joinToken] = parts;

    if (!RegExp(r'^\d{6}$').hasMatch(voyageCode)) {
      throw const FormatException('That invitation has no valid voyage code.');
    }
    if (voyageId.isEmpty || voyageId.length > 128) {
      throw const FormatException('That invitation has no valid voyage.');
    }
    // Below 16 characters the secret cannot drive authenticated transport - the
    // relay, push registration and the event authenticator all check the same
    // floor - so accepting a shorter one would produce a session that looks
    // joined and silently cannot talk to anybody.
    if (inviteSecret.length < 16 || inviteSecret.length > 512) {
      throw const FormatException(
        'That invitation is incomplete and cannot join securely.',
      );
    }
    if (joinToken.length < 16 || joinToken.length > 128) {
      throw const FormatException(
        'That invitation is incomplete and cannot join securely.',
      );
    }
    return VoyageJoinPayload(
      voyageId: voyageId,
      voyageCode: voyageCode,
      inviteSecret: inviteSecret,
      joinToken: joinToken,
    );
  }

  /// Never includes the secrets. A payload's `toString` reaches logs and error
  /// reports, and a voyage secret has no business in either.
  @override
  String toString() => 'VoyageJoinPayload(voyage $voyageCode)';
}
