package app.alextran.immich

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.ext.SdkExtensions
import app.alextran.immich.background.BackgroundEngineLock
import app.alextran.immich.background.BackgroundWorkerApiImpl
import app.alextran.immich.background.BackgroundWorkerFgHostApi
import app.alextran.immich.background.BackgroundWorkerLockApi
import app.alextran.immich.camera.CameraLiveApi
import app.alextran.immich.camera.CameraLiveApiImpl
import app.alextran.immich.camera.CameraLiveViewFactory
import app.alextran.immich.connectivity.ConnectivityApi
import app.alextran.immich.connectivity.ConnectivityApiImpl
import app.alextran.immich.core.HttpClientManager
import app.alextran.immich.core.ImmichPlugin
import app.alextran.immich.core.NetworkApiPlugin
import me.albemala.native_video_player.NativeVideoPlayerPlugin
import app.alextran.immich.images.LocalImageApi
import app.alextran.immich.immersive.ImmersiveApi
import app.alextran.immich.immersive.ImmersiveApiImpl
import app.alextran.immich.images.LocalImagesImpl
import app.alextran.immich.images.RemoteImageApi
import app.alextran.immich.images.RemoteImagesImpl
import app.alextran.immich.permission.PermissionApi
import app.alextran.immich.permission.PermissionApiImpl
import app.alextran.immich.phoneshare.PhoneShareApi
import app.alextran.immich.phoneshare.PhoneShareApiImpl
import app.alextran.immich.phoneshare.PhoneShareService
import app.alextran.immich.spatial.SpatialVideoApi
import app.alextran.immich.spatial.SpatialVideoApiImpl
import app.alextran.immich.spherical.SphericalVideoApi
import app.alextran.immich.spherical.SphericalVideoApiImpl
import app.alextran.immich.sync.NativeSyncApi
import app.alextran.immich.sync.NativeSyncApiImpl26
import app.alextran.immich.sync.NativeSyncApiImpl30
import app.alextran.immich.tv.TvApi
import app.alextran.immich.tv.TvApiImpl
import app.alextran.immich.videodecoder.VideoDecoderApi
import app.alextran.immich.videodecoder.VideoDecoderApiImpl
import app.alextran.immich.videothumbnail.VideoThumbnailApi
import app.alextran.immich.videothumbnail.VideoThumbnailApiImpl
import app.alextran.immich.viewintent.ViewIntentPlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    registerPlugins(this, flutterEngine)
    // Only the engine of the app UI hears when the 360° and Spatial 2.5D players close, not the background engines
    SphericalVideoApiImpl.attachEvents(flutterEngine.dartExecutor.binaryMessenger)
    SpatialVideoApiImpl.attachEvents(flutterEngine.dartExecutor.binaryMessenger)
    ImmersiveApiImpl.attachEvents(flutterEngine.dartExecutor.binaryMessenger)
    // The Stop action of the phone share notification, for the engine that runs the share
    PhoneShareApiImpl.attachEvents(flutterEngine.dartExecutor.binaryMessenger)
    val messenger = flutterEngine.dartExecutor.binaryMessenger
    // TV detection and the native text dialog of the remote control layout: they need this activity
    TvApi.setUp(messenger, TvApiImpl(this))
    // Live view of the Tapo cameras: a platform view and the API that feeds it
    val cameraLiveViews = CameraLiveViewFactory(messenger)
    flutterEngine.platformViewsController.registry.registerViewFactory(CameraLiveViewFactory.VIEW_TYPE, cameraLiveViews)
    CameraLiveApi.setUp(messenger, CameraLiveApiImpl(cameraLiveViews))
  }

  override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    // The engine goes away: the 360° and Spatial 2.5D players must not keep it alive
    SphericalVideoApiImpl.detachEvents(flutterEngine.dartExecutor.binaryMessenger)
    SpatialVideoApiImpl.detachEvents(flutterEngine.dartExecutor.binaryMessenger)
    ImmersiveApiImpl.detachEvents(flutterEngine.dartExecutor.binaryMessenger)
    PhoneShareApiImpl.detachEvents(flutterEngine.dartExecutor.binaryMessenger)
    // The TV dialog must not keep this activity once it is gone
    TvApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
    CameraLiveApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
    super.cleanUpFlutterEngine(flutterEngine)
  }

  override fun onDestroy() {
    // The app is closed: the phone share served from its engine is gone, its foreground service must not stay
    if (isFinishing) {
      PhoneShareService.stop(this)
    }
    super.onDestroy()
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
  }

  companion object {
    fun registerPlugins(ctx: Context, flutterEngine: FlutterEngine) {
      HttpClientManager.initialize(ctx)
      NativeVideoPlayerPlugin.dataSourceFactory = HttpClientManager::createDataSourceFactory
      flutterEngine.plugins.add(NetworkApiPlugin())

      val messenger = flutterEngine.dartExecutor.binaryMessenger
      val backgroundEngineLockImpl = BackgroundEngineLock(ctx)
      BackgroundWorkerLockApi.setUp(messenger, backgroundEngineLockImpl)
      val nativeSyncApiImpl =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) < 1) {
          NativeSyncApiImpl26(ctx)
        } else {
          NativeSyncApiImpl30(ctx)
        }
      val permissionApiImpl = PermissionApiImpl(ctx)
      NativeSyncApi.setUp(messenger, nativeSyncApiImpl)
      PermissionApi.setUp(messenger, permissionApiImpl)
      LocalImageApi.setUp(messenger, LocalImagesImpl(ctx))
      RemoteImageApi.setUp(messenger, RemoteImagesImpl(ctx))

      BackgroundWorkerFgHostApi.setUp(messenger, BackgroundWorkerApiImpl(ctx))
      ConnectivityApi.setUp(messenger, ConnectivityApiImpl(ctx))
      SphericalVideoApi.setUp(messenger, SphericalVideoApiImpl(ctx))
      SpatialVideoApi.setUp(messenger, SpatialVideoApiImpl(ctx))
      ImmersiveApi.setUp(messenger, ImmersiveApiImpl(ctx))
      PhoneShareApi.setUp(messenger, PhoneShareApiImpl(ctx))
      VideoThumbnailApi.setUp(messenger, VideoThumbnailApiImpl())
      VideoDecoderApi.setUp(messenger, VideoDecoderApiImpl())

      flutterEngine.plugins.add(ViewIntentPlugin())
      flutterEngine.plugins.add(backgroundEngineLockImpl)
      flutterEngine.plugins.add(nativeSyncApiImpl)
      flutterEngine.plugins.add(permissionApiImpl)
    }

    fun cancelPlugins(flutterEngine: FlutterEngine) {
      val nativeApi =
        flutterEngine.plugins.get(NativeSyncApiImpl26::class.java) as ImmichPlugin?
          ?: flutterEngine.plugins.get(NativeSyncApiImpl30::class.java) as ImmichPlugin?
      nativeApi?.detachFromEngine()
      val permissionApi = flutterEngine.plugins.get(PermissionApiImpl::class.java) as ImmichPlugin?
      permissionApi?.detachFromEngine()
    }
  }
}
