import Flutter
import NearbyConnections
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nearbyChannel: FlutterMethodChannel?
  private var nearbyEventChannel: FlutterEventChannel?
  private var nearbyEventSink: FlutterEventSink?
  private var connectionManager: ConnectionManager?
  private var advertiser: Advertiser?
  private var discoverer: Discoverer?
  private var connectedPeers = Set<EndpointID>()
  private var pendingPeers = Set<EndpointID>()
  private var gpxImportChannel: FlutterMethodChannel?
  private var pendingGpxImport: (data: Data, fileName: String)?
  private var plannerLinkChannel: FlutterMethodChannel?
  private var pendingPlannerLink: String?
  private var pendingVoyageInvitationLink: String?
  private var pushChannel: FlutterMethodChannel?
  private var apnsToken: String?
  private var pendingPushTokenResult: FlutterResult?
  private var pendingOpenedPush: [String: String]?
  private var pushTokenTimeout: DispatchWorkItem?
  private var backgroundLocationPermissionBridge: BackgroundLocationPermissionBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    UNUserNotificationCenter.current().delegate = self
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    backgroundLocationPermissionBridge = BackgroundLocationPermissionBridge(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    let channel = FlutterMethodChannel(
      name: "me.osholt.tide_and_seek/nearby",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getCapabilities":
        result([
          "platform": "ios",
          "nativeBridgeReady": true,
          "nearbyApiLinked": true,
          "status": "hardwareValidationRequired",
        ])
      case "requestPermissions":
        // iOS presents Bluetooth/local-network consent when discovery starts.
        result(true)
      case "start":
        guard
          let arguments = call.arguments as? [String: Any],
          let serviceID = arguments["serviceId"] as? String,
          let endpointName = arguments["endpointName"] as? String
        else {
          result(FlutterError(code: "invalid_arguments", message: "Missing nearby configuration", details: nil))
          return
        }
        self.startNearby(serviceID: serviceID, endpointName: String(endpointName.prefix(32)), result: result)
      case "send":
        guard
          let arguments = call.arguments as? [String: Any],
          let typedData = arguments["bytes"] as? FlutterStandardTypedData,
          let peerIDs = arguments["peerIds"] as? [String],
          !peerIDs.isEmpty,
          let manager = self.connectionManager
        else {
          result(FlutterError(code: "invalid_arguments", message: "Bytes and peer IDs are required", details: nil))
          return
        }
        _ = manager.send(typedData.data, to: peerIDs) { error in
          if let error {
            result(FlutterError(code: "send_failed", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      case "stop":
        self.stopNearby()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    nearbyChannel = channel

    let eventChannel = FlutterEventChannel(
      name: "me.osholt.tide_and_seek/nearby_events",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    eventChannel.setStreamHandler(self)
    nearbyEventChannel = eventChannel

    let gpxChannel = FlutterMethodChannel(
      name: "me.osholt.tide_and_seek/gpx_import",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    gpxChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "consumePendingGpxImport" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let pending = self?.pendingGpxImport else {
        result(nil)
        return
      }
      self?.pendingGpxImport = nil
      result([
        "bytes": FlutterStandardTypedData(bytes: pending.data),
        "fileName": pending.fileName,
      ])
    }
    gpxImportChannel = gpxChannel

    let plannerChannel = FlutterMethodChannel(
      name: "me.osholt.tide_and_seek/planner_link",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    plannerChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "consumePendingPlannerLink":
        let pending = self?.pendingPlannerLink
        self?.pendingPlannerLink = nil
        result(pending)
      case "consumePendingVoyageInvitationLink":
        let pending = self?.pendingVoyageInvitationLink
        self?.pendingVoyageInvitationLink = nil
        result(pending)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    plannerLinkChannel = plannerChannel

    let pushChannel = FlutterMethodChannel(
      name: "me.osholt.tide_and_seek/push",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    pushChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "configureAndRequest":
        self?.requestPushPermission(result: result)
      case "currentStatus":
        self?.currentPushStatus(result: result)
      case "consumeInitialNotification":
        let pending = self?.pendingOpenedPush
        self?.pendingOpenedPush = nil
        result(pending)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.pushChannel = pushChannel

  }

  private func requestPushPermission(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.currentPushStatus(result: result)
      }
    }
  }

  private func currentPushStatus(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
      DispatchQueue.main.async {
        guard let self else {
          result([
            "permission": "unavailable",
            "platform": "ios",
            "provider": "apns",
          ])
          return
        }
        let permission = self.pushPermission(settings.authorizationStatus)
        guard permission == "granted" else {
          result(self.pushStatus(permission: permission))
          return
        }
        if self.apnsToken != nil {
          result(self.pushStatus(permission: permission))
          UIApplication.shared.registerForRemoteNotifications()
          return
        }
        guard self.pendingPushTokenResult == nil else {
          result(
            FlutterError(
              code: "push_registration_pending",
              message: "Push registration is already in progress",
              details: nil
            )
          )
          return
        }
        self.pendingPushTokenResult = result
        UIApplication.shared.registerForRemoteNotifications()
        let timeout = DispatchWorkItem { [weak self] in
          guard let self, let pending = self.pendingPushTokenResult else { return }
          self.pendingPushTokenResult = nil
          pending(self.pushStatus(permission: "granted"))
        }
        self.pushTokenTimeout?.cancel()
        self.pushTokenTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
      }
    }
  }

  private func pushPermission(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized, .provisional, .ephemeral:
      return "granted"
    case .denied:
      return "denied"
    case .notDetermined:
      return "unknown"
    @unknown default:
      return "unavailable"
    }
  }

  private func pushStatus(permission: String) -> [String: String] {
    var status = [
      "permission": permission,
      "platform": "ios",
      "provider": "apns",
    ]
    if let apnsToken {
      status["token"] = apnsToken
    }
    return status
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    let changed = apnsToken != nil && apnsToken != token
    apnsToken = token
    pushTokenTimeout?.cancel()
    pushTokenTimeout = nil
    if let pending = pendingPushTokenResult {
      pendingPushTokenResult = nil
      pending(pushStatus(permission: "granted"))
    } else if changed {
      pushChannel?.invokeMethod(
        "tokenRotated",
        arguments: pushStatus(permission: "granted")
      )
    }
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
    pushTokenTimeout?.cancel()
    pushTokenTimeout = nil
    if let pending = pendingPushTokenResult {
      pendingPushTokenResult = nil
      pending(pushStatus(permission: "granted"))
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // The durable in-app alert is already visible while the app is active.
    completionHandler([])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    handlePushNotification(userInfo: response.notification.request.content.userInfo)
    completionHandler()
  }

  func handlePushNotification(userInfo: [AnyHashable: Any]) {
    guard
      let voyageID = userInfo["voyageId"] as? String,
      let eventID = userInfo["eventId"] as? String,
      let category = userInfo["category"] as? String,
      !voyageID.isEmpty,
      !eventID.isEmpty
    else { return }
    let value = [
      "voyageId": voyageID,
      "eventId": eventID,
      "category": category,
    ]
    pendingOpenedPush = value
    pushChannel?.invokeMethod("notificationOpened", arguments: value)
  }

  /// Called from SceneDelegate when the OS hands this app a file URL (Open
  /// in..., a share sheet, or a cold launch from one of those). Dart pulls
  /// this on its own schedule via consumePendingGpxImport rather than being
  /// pushed to live, since a cold-start URL arrives before Dart's engine -
  /// and therefore any method call handler - is guaranteed to exist yet.
  func handleIncomingGpx(url: URL) {
    let isSecurityScoped = url.startAccessingSecurityScopedResource()
    defer {
      if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
    }
    guard let data = try? Data(contentsOf: url) else { return }
    pendingGpxImport = (data: data, fileName: url.lastPathComponent)
  }

  func handleIncomingAppLink(url: URL) {
    guard
      url.scheme == "https",
      url.host?.lowercased() == "tideandseek.invalid",
      url.absoluteString.count <= 2048
    else { return }
    switch url.path {
    case "/planner.html": pendingPlannerLink = url.absoluteString
    case "/join.html": pendingVoyageInvitationLink = url.absoluteString
    default: return
    }
  }

  private func startNearby(serviceID: String, endpointName: String, result: @escaping FlutterResult) {
    stopNearby()
    emitStatus("starting")
    let manager = ConnectionManager(serviceID: serviceID, strategy: .cluster)
    manager.delegate = self
    manager.enableBLEV2()
    let advertiser = Advertiser(connectionManager: manager)
    advertiser.delegate = self
    let discoverer = Discoverer(connectionManager: manager)
    discoverer.delegate = self
    connectionManager = manager
    self.advertiser = advertiser
    self.discoverer = discoverer

    let group = DispatchGroup()
    var startError: Error?
    group.enter()
    advertiser.startAdvertising(using: Data(endpointName.utf8)) { error in
      startError = startError ?? error
      group.leave()
    }
    group.enter()
    discoverer.startDiscovery { error in
      startError = startError ?? error
      group.leave()
    }
    group.notify(queue: .main) { [weak self] in
      if let startError {
        self?.stopNearby()
        self?.emitStatus("failed", message: startError.localizedDescription)
        result(FlutterError(code: "start_failed", message: startError.localizedDescription, details: nil))
      } else {
        self?.emitStatus("searching")
        result(nil)
      }
    }
  }

  private func stopNearby() {
    advertiser?.stopAdvertising()
    discoverer?.stopDiscovery()
    for peerID in connectedPeers {
      connectionManager?.disconnect(from: peerID)
    }
    advertiser = nil
    discoverer = nil
    connectionManager = nil
    connectedPeers.removeAll()
    pendingPeers.removeAll()
    emitStatus("stopped")
  }

  private func emitStatus(_ state: String, message: String? = nil) {
    nearbyEventSink?([
      "kind": "status",
      "state": state,
      "peerIds": Array(connectedPeers),
      "message": message as Any,
    ])
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    nearbyEventSink = events
    emitStatus(connectedPeers.isEmpty ? "stopped" : "connected")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    nearbyEventSink = nil
    return nil
  }
}

extension AppDelegate: DiscovererDelegate {
  func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
    guard !connectedPeers.contains(endpointID), pendingPeers.insert(endpointID).inserted else { return }
    discoverer.requestConnection(to: endpointID, using: Data("Tide and Seek".utf8)) { [weak self] error in
      if let error {
        self?.pendingPeers.remove(endpointID)
        self?.emitStatus("searching", message: "Connection request failed: \(error.localizedDescription)")
      }
    }
  }

  func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
    pendingPeers.remove(endpointID)
  }
}

extension AppDelegate: AdvertiserDelegate {
  func advertiser(
    _ advertiser: Advertiser,
    didReceiveConnectionRequestFrom endpointID: EndpointID,
    with context: Data,
    connectionRequestHandler: @escaping (Bool) -> Void
  ) {
    pendingPeers.insert(endpointID)
    connectionRequestHandler(true)
  }
}

extension AppDelegate: ConnectionManagerDelegate {
  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive verificationCode: String,
    from endpointID: EndpointID,
    verificationHandler: @escaping (Bool) -> Void
  ) {
    // Development alpha: app-layer voyage-secret HMAC authenticates every frame.
    // Hardware validation must revisit user-visible Nearby token verification.
    verificationHandler(true)
  }

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive data: Data,
    withID payloadID: PayloadID,
    from endpointID: EndpointID
  ) {
    nearbyEventSink?([
      "kind": "packet",
      "peerId": endpointID,
      "bytes": FlutterStandardTypedData(bytes: data),
    ])
  }

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive stream: InputStream,
    withID payloadID: PayloadID,
    from endpointID: EndpointID,
    cancellationToken token: CancellationToken
  ) {}

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didStartReceivingResourceWithID payloadID: PayloadID,
    from endpointID: EndpointID,
    at localURL: URL,
    withName name: String,
    cancellationToken token: CancellationToken
  ) {}

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceiveTransferUpdate update: TransferUpdate,
    from endpointID: EndpointID,
    forPayload payloadID: PayloadID
  ) {}

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didChangeTo state: ConnectionState,
    for endpointID: EndpointID
  ) {
    switch state {
    case .connected:
      pendingPeers.remove(endpointID)
      connectedPeers.insert(endpointID)
      emitStatus("connected")
    case .disconnected:
      pendingPeers.remove(endpointID)
      connectedPeers.remove(endpointID)
      emitStatus(connectedPeers.isEmpty ? "searching" : "connected")
    case .rejected:
      pendingPeers.remove(endpointID)
      emitStatus("searching", message: "Nearby connection rejected")
    case .connecting:
      break
    }
  }
}
