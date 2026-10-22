import native_video_player

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required for flutter_local_notification
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }

    SwiftNativeVideoPlayerPlugin.cookieStorage = URLSessionManager.cookieStorage
    URLSessionManager.patchBackgroundDownloader()
    BackgroundWorkerApiImpl.registerBackgroundWorkers()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    AppDelegate.registerPlugins(with: engineBridge.pluginRegistry, messenger: messenger)
    // The scanner of "Connect a TV or computer" shows a view controller: the app's engine only, not the background ones
    QrScanApiSetup.setUp(binaryMessenger: messenger, api: QrScanApiImpl())
  }

  public static func registerPlugins(with registry: FlutterPluginRegistry, messenger: FlutterBinaryMessenger) {
    NativeSyncApiImpl.register(with: registry.registrar(forPlugin: NativeSyncApiImpl.name)!)
    PermissionApiSetup.setUp(binaryMessenger: messenger, api: PermissionApiImpl())
    LocalImageApiSetup.setUp(binaryMessenger: messenger, api: LocalImageApiImpl())
    RemoteImageApiSetup.setUp(binaryMessenger: messenger, api: RemoteImageApiImpl())
    BackgroundWorkerFgHostApiSetup.setUp(binaryMessenger: messenger, api: BackgroundWorkerApiImpl())
    ConnectivityApiSetup.setUp(binaryMessenger: messenger, api: ConnectivityApiImpl())
    NetworkApiSetup.setUp(binaryMessenger: messenger, api: NetworkApiImpl())
    SphericalVideoApiSetup.setUp(
      binaryMessenger: messenger,
      api: SphericalVideoApiImpl(events: SphericalVideoEvents(binaryMessenger: messenger))
    )
    SpatialVideoApiSetup.setUp(
      binaryMessenger: messenger,
      api: SpatialVideoApiImpl(events: SpatialVideoEvents(binaryMessenger: messenger))
    )
    VideoThumbnailApiSetup.setUp(binaryMessenger: messenger, api: VideoThumbnailApiImpl())
    VideoDecoderApiSetup.setUp(binaryMessenger: messenger, api: VideoDecoderApiImpl())
    PhoneShareApiSetup.setUp(binaryMessenger: messenger, api: PhoneShareApiImpl())
    // The live view of the Tapo cameras: the platform view and what Flutter asks of it
    let cameraLiveViews = CameraLiveViewFactory(messenger: messenger)
    registry.registrar(forPlugin: "CameraLiveViewFactory")?.register(
      cameraLiveViews,
      withId: CameraLiveViewFactory.viewType
    )
    CameraLiveApiSetup.setUp(binaryMessenger: messenger, api: CameraLiveApiImpl(views: cameraLiveViews))
  }

  public static func cancelPlugins(with engine: FlutterEngine) {
    (engine.valuePublished(byPlugin: NativeSyncApiImpl.name) as? NativeSyncApiImpl)?.detachFromEngine()
  }
}
