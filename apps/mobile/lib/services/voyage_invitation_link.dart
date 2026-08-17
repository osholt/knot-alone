import 'package:flutter/services.dart';

import '../domain/join_invite.dart';

const voyageInvitationPath = '/join.html';

/// A private, server-resolvable invitation captured from an App/Universal Link.
///
/// The token is capability material. It is deliberately carried only in the URL
/// fragment, which browsers do not send to the web server or in referrer
/// headers. The relay still resolves and validates it when the sailor joins, so
/// an expired or revoked voyage gets the same explanation as paste-to-join.
class VoyageInvitationLink {
  const VoyageInvitationLink({
    required this.voyageCode,
    required this.joinToken,
  });

  final String voyageCode;
  final String joinToken;
}

abstract interface class IncomingVoyageInvitationLinkSource {
  Future<String?> consumePending();
}

/// Pulls the latest voyage-invitation link captured by the native lifecycle
/// bridge. Pull delivery handles both cold starts and warm resumes without an
/// event-listener race.
class VoyageInvitationLinkChannel
    implements IncomingVoyageInvitationLinkSource {
  const VoyageInvitationLinkChannel();

  static const _channel = MethodChannel('me.osholt.tide_and_seek/planner_link');

  @override
  Future<String?> consumePending() async {
    try {
      return await _channel.invokeMethod<String>(
        'consumePendingVoyageInvitationLink',
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// Builds the only invitation URL format the app shares.
///
/// [Uri.replace] percent-encodes the `#` inside `code#token`; it remains inside
/// the outer URL fragment and is decoded again by [Uri.fragment].
String voyageInvitationUrl(String voyageCode, String joinToken) {
  final invitation = joinInviteText(voyageCode, joinToken);
  final parsed = parseJoinInvite(invitation);
  if (parsed.code != voyageCode || parsed.token != joinToken) {
    throw const FormatException('Cannot create an invalid voyage invitation.');
  }
  return Uri.https(
    'tideandseek.invalid',
    voyageInvitationPath,
  ).replace(fragment: invitation).toString();
}

/// Parses a Tide and Seek invitation link without ever logging its fragment.
VoyageInvitationLink? voyageInvitationFromLink(String value) {
  if (value.length > 2048) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != 'tideandseek.invalid' ||
      uri.path != voyageInvitationPath ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasQuery ||
      !uri.hasFragment) {
    return null;
  }

  final String fragment;
  try {
    fragment = Uri.decodeComponent(uri.fragment);
  } on FormatException {
    return null;
  }
  final invite = parseJoinInvite(fragment);
  final code = invite.code;
  final token = invite.token;
  if (code == null || token == null) return null;

  // Reject prose or extra capability material around the invitation. Sharing
  // text may contain prose, but the URL fragment itself has one exact grammar.
  if (fragment.trim() != joinInviteText(code, token)) return null;
  return VoyageInvitationLink(voyageCode: code, joinToken: token);
}
