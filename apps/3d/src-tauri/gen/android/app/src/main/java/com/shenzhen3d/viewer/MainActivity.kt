package com.shenzhen3d.viewer

import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.View
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
 *
 * The keyboard: drawn edge to edge, the window no longer shrinks for it (adjustResize does nothing from Android 15
 * on), so the WebView would stay full height under the keyboard and the page would never learn it is there. Its
 * container is padded by the keyboard's height instead, so the WebView ends where the keyboard begins, as it did
 * before, and every field and the page's layout see the space that is left. The bottom inset is then the
 * keyboard's (the navigation bar is behind it), and the page is told the keyboard's height as `keyboard`.
 */
class MainActivity : TauriActivity() {
  @Volatile private var insets = "{\"top\":0,\"right\":0,\"bottom\":0,\"left\":0,\"keyboard\":0}"
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
      // From the screen's bottom edge to the keyboard's top, the navigation bar included; 0 without a keyboard.
      val keyboard = if (all.isVisible(WindowInsetsCompat.Type.ime())) {
        all.getInsets(WindowInsetsCompat.Type.ime()).bottom
      } else 0
      val container = (view.parent as? View) ?: findViewById(android.R.id.content)
      if (container != null && container.paddingBottom != keyboard) {
        container.setPadding(container.paddingLeft, container.paddingTop, container.paddingRight, keyboard)
      }
      val bottom = if (keyboard > 0) 0 else bars.bottom
      val density = view.resources.displayMetrics.density
      fun css(px: Int) = String.format(Locale.ROOT, "%.2f", px / density)
      val next = "{\"top\":${css(bars.top)},\"right\":${css(bars.right)}," +
        "\"bottom\":${css(bottom)},\"left\":${css(bars.left)},\"keyboard\":${css(keyboard)}}"
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
        // What shows for a moment under the keyboard while it slides in, before the page has made room for it.
        window.decorView.setBackgroundColor(if (light) Color.rgb(243, 246, 246) else Color.rgb(21, 28, 32))
      }
    }
  }
}
