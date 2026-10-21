package com.shenzhen3d.viewer

import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import java.util.Locale

/**
 * Edge to edge: the page fills the whole screen, behind the status bar, the navigation bar or gesture handle, and any
 * display cutout, in portrait and landscape. The page keeps its controls clear of them with the system's insets,
 * which it reads as CSS pixels from `window.ShenzhenInsets` (src/core/safe-area.ts) because Android's WebView does
 * not reliably report them through CSS env(safe-area-inset-*); an `shenzhen-insets` event says when they change.
 */
class MainActivity : TauriActivity() {
  @Volatile private var insets = "{\"top\":0,\"right\":0,\"bottom\":0,\"left\":0}"
  private var webView: WebView? = null

  override fun onCreate(savedInstanceState: Bundle?) {
    // Transparent bars with light icons, as the app's dark theme wants; the page asks for dark icons in its light theme.
    enableEdgeToEdge(
      statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
      navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT)
    )
    super.onCreate(savedInstanceState)
    // No scrim over the page behind a three-button navigation bar: the page keeps its own controls clear of it.
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      window.isNavigationBarContrastEnforced = false
      window.isStatusBarContrastEnforced = false
    }
    window.decorView.setBackgroundColor(Color.rgb(21, 28, 32))
  }

  override fun onWebViewCreate(webView: WebView) {
    this.webView = webView
    webView.addJavascriptInterface(Bridge(), "ShenzhenInsets")
    ViewCompat.setOnApplyWindowInsetsListener(webView) { view, all ->
      val bars = all.getInsets(
        WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
      )
      val density = view.resources.displayMetrics.density
      fun css(px: Int) = String.format(Locale.ROOT, "%.2f", px / density)
      val next = "{\"top\":${css(bars.top)},\"right\":${css(bars.right)}," +
        "\"bottom\":${css(bars.bottom)},\"left\":${css(bars.left)}}"
      if (next != insets) {
        insets = next
        view.post {
          (view as WebView).evaluateJavascript(
            "window.dispatchEvent(new Event('shenzhen-insets'))", null
          )
        }
      }
      // Not consumed: the WebView may use them too.
      all
    }
    ViewCompat.requestApplyInsets(webView)
  }

  private inner class Bridge {
    @JavascriptInterface
    fun insets(): String = this@MainActivity.insets

    /** Dark status and navigation bar icons over a light page, light ones over a dark page. */
    @JavascriptInterface
    fun lightPage(light: Boolean) {
      runOnUiThread {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.isAppearanceLightStatusBars = light
        controller.isAppearanceLightNavigationBars = light
      }
    }
  }
}
