package app.alextran.immich.splatviewer

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import app.alextran.immich.BuildConfig

private const val TAG = "SplatViewer"

/**
 * The splat viewer of the Android phones and tablets (lot SV6 of the splat viewer, plan section 2.6): a WebView, full
 * screen with the system bars hidden and the screen kept on, that shows the page the app serves on its media bridge.
 * The page loads the splat, places it and moves in it, and talks to the app over HTTP; this activity only keeps the
 * WebView to the session's folder, closes on Back and says how it closed. A rotation does not load the page again
 * (configChanges in the manifest). A renderer killed for memory closes the viewer with rendererGone, without taking the
 * app down. Nothing is cached and no JavaScript interface is added.
 */
class SplatViewerActivity : ComponentActivity() {
  companion object {
    private const val EXTRA_URL = "url"
    private const val EXTRA_TITLE = "title"

    /** The viewer on screen, to close it from Flutter; read and written on the main thread */
    var current: SplatViewerActivity? = null
      private set

    fun intent(context: Context, url: String, title: String): Intent =
      Intent(context, SplatViewerActivity::class.java)
        .putExtra(EXTRA_URL, url)
        .putExtra(EXTRA_TITLE, title)
  }

  private var webView: WebView? = null
  private var reason = "user"
  private var told = false

  @SuppressLint("SetJavaScriptEnabled")
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    current = this
    val url = intent.getStringExtra(EXTRA_URL)
    if (url == null) {
      finishWith("error")
      return
    }
    title = intent.getStringExtra(EXTRA_TITLE) ?: ""
    val major = SplatViewerRules.majorOf(WebView.getCurrentWebViewPackage()?.versionName)
    if (!SplatViewerRules.canShow(major)) {
      Log.w(TAG, "Android System WebView $major cannot show the splat viewer")
      finishWith("noWebView")
      return
    }
    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    window.decorView.setBackgroundColor(Color.BLACK)
    WindowCompat.setDecorFitsSystemWindows(window, false)
    WindowInsetsControllerCompat(window, window.decorView).apply {
      hide(WindowInsetsCompat.Type.systemBars())
      systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
    }

    val prefix = SplatViewerRules.prefixOf(url)
    WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
    val view =
      try {
        WebView(this)
      } catch (error: Exception) {
        // No WebView installed, or one being updated
        Log.w(TAG, "No WebView for the splat viewer", error)
        finishWith("noWebView")
        return
      }
    view.setBackgroundColor(Color.BLACK)
    view.overScrollMode = View.OVER_SCROLL_NEVER
    view.isHorizontalScrollBarEnabled = false
    view.isVerticalScrollBarEnabled = false
    with(view.settings) {
      javaScriptEnabled = true
      domStorageEnabled = false
      cacheMode = WebSettings.LOAD_NO_CACHE
      setSupportZoom(false)
      builtInZoomControls = false
      displayZoomControls = false
      allowFileAccess = false
      allowContentAccess = false
      mediaPlaybackRequiresUserGesture = true
      setGeolocationEnabled(false)
    }
    view.webChromeClient = WebChromeClient()
    view.webViewClient =
      object : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
          val allowed = SplatViewerRules.allows(prefix, request.url.toString())
          if (!allowed) Log.w(TAG, "The splat viewer was kept from leaving its page")
          return !allowed
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
          if (request.isForMainFrame) {
            Log.w(TAG, "The splat viewer page did not load: ${error.errorCode} ${error.description}")
            finishWith("error")
          }
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
          // Returning true keeps the app alive: the WebView is dropped and the viewer closes, the app says why
          Log.w(TAG, "The renderer of the splat viewer is gone (crashed: ${detail.didCrash()})")
          destroyWebView()
          finishWith("rendererGone")
          return true
        }
      }
    setContentView(FrameLayout(this).apply { addView(view, FrameLayout.LayoutParams(-1, -1)) })
    webView = view
    onBackPressedDispatcher.addCallback(
      this,
      object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() = finishWith("user")
      },
    )
    if (!SplatViewerRules.allows(prefix, url)) {
      finishWith("error")
      return
    }
    view.loadUrl(url)
  }

  override fun onResume() {
    super.onResume()
    webView?.onResume()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      webView?.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)
    }
  }

  override fun onPause() {
    webView?.onPause()
    super.onPause()
  }

  /** Closes the viewer, its [reason] told to Flutter once */
  fun finishWith(reason: String) {
    this.reason = reason
    if (!isFinishing) finish()
  }

  private fun destroyWebView() {
    val view = webView ?: return
    webView = null
    (view.parent as? FrameLayout)?.removeView(view)
    view.destroy()
  }

  override fun onDestroy() {
    destroyWebView()
    if (current === this) current = null
    if (!told && isFinishing) {
      told = true
      SplatViewerApiImpl.notifyClosed(reason)
    }
    super.onDestroy()
  }
}
