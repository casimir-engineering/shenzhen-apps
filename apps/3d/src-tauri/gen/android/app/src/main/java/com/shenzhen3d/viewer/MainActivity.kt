package com.shenzhen3d.viewer

import android.graphics.Color
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import java.util.Locale
import kotlin.math.max

private const val KEYBOARD_MIN_DP = 100

/**
 * Edge to edge: the page fills the whole screen, behind the status bar, the navigation bar or gesture handle, and any
 * display cutout, in portrait and landscape. The page keeps its controls clear of them with the system's insets,
 * which it reads as CSS pixels from `window.ShenzhenInsets` (src/core/safe-area.ts) because Android's WebView does
 * not reliably report them through CSS env(safe-area-inset-*); an `shenzhen-insets` event says when they change.
 *
 * The keyboard: drawn edge to edge, the window no longer shrinks for it (adjustResize does nothing from Android 15
 * on), so the WebView would stay full height under the keyboard. Its container is padded by the keyboard's height
 * instead, so the WebView ends where the keyboard begins and every field and the page's layout see the space that is
 * left. The bottom inset is then the keyboard's (the navigation bar is behind it), and the page is told the keyboard's
 * height as `keyboard`.
 *
 * The activity asks for adjustResize (AndroidManifest.xml). Without it Android pans the window instead, which cannot
 * bring a field of a full-screen WebView into sight, and some phones (the owner's POCO F7, HyperOS on Android 15) then
 * never put the keyboard in this window's insets, so nothing made room for it. The keyboard's height is read from both
 * the insets and the window's visible frame, which ends where the keyboard begins, whichever the phone reports.
 */
class MainActivity : TauriActivity() {
  @Volatile private var insets = "{\"top\":0,\"right\":0,\"bottom\":0,\"left\":0,\"keyboard\":0}"
  private var webView: WebView? = null
  /** The system bars and display cutout, and the keyboard as the insets give it, in screen pixels. */
  private var bars = Insets.NONE
  private var imeInset = 0
  /**
   * Tests only (debug builds, scripts/friends/phones-keyboard.mjs --withhold-ime): the insets reach the page without the
   * keyboard in them, as on phones whose system does not report it to this window, so the emulator shows what they do.
   */
  private var withholdIme = false

  override fun onCreate(savedInstanceState: Bundle?) {
    // Transparent bars with light icons, as the app's dark theme wants; the page asks for dark icons in its light theme.
    enableEdgeToEdge(
      statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
      navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT)
    )
    super.onCreate(savedInstanceState)
    withholdIme = BuildConfig.DEBUG && intent.getBooleanExtra("withholdIme", false)
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
    ViewCompat.setOnApplyWindowInsetsListener(webView) { view, given ->
      val all = if (withholdIme) {
        WindowInsetsCompat.Builder(given).setInsets(WindowInsetsCompat.Type.ime(), Insets.NONE)
          .setVisible(WindowInsetsCompat.Type.ime(), false).build()
      } else given
      bars = all.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
      // Its height, whether or not the system also calls it visible (some phones do not while it is up).
      imeInset = all.getInsets(WindowInsetsCompat.Type.ime()).bottom
      fit(view as WebView)
      // This listener stands in for the WebView's own handling, so it never makes room for the keyboard twice.
      all
    }
    // Every layout, the keyboard coming up or down among them: the visible frame, for phones whose insets lack it.
    webView.viewTreeObserver.addOnGlobalLayoutListener { fit(webView) }
    ViewCompat.requestApplyInsets(webView)
  }

  /** From the screen's bottom edge to the keyboard's top, the navigation bar included; 0 without a keyboard. */
  private fun keyboardHeight(view: View): Int {
    val root = view.rootView
    val visible = Rect().also { root.getWindowVisibleDisplayFrame(it) }
    val at = IntArray(2).also { root.getLocationOnScreen(it) }
    val hidden = at[1] + root.height - visible.bottom
    // The navigation bar alone is not a keyboard; the smallest keyboard is taller than this.
    val keyboard = hidden - bars.bottom > KEYBOARD_MIN_DP * view.resources.displayMetrics.density
    return max(imeInset, if (keyboard) hidden else 0)
  }

  private fun fit(view: WebView) {
    val container = view.parent as? View ?: return
    val keyboard = keyboardHeight(view)
    if (container.paddingBottom != keyboard) {
      container.setPadding(container.paddingLeft, container.paddingTop, container.paddingRight, keyboard)
    }
    val bottom = if (keyboard > 0) 0 else bars.bottom
    val density = view.resources.displayMetrics.density
    fun css(px: Int) = String.format(Locale.ROOT, "%.2f", px / density)
    val next = "{\"top\":${css(bars.top)},\"right\":${css(bars.right)}," +
      "\"bottom\":${css(bottom)},\"left\":${css(bars.left)},\"keyboard\":${css(keyboard)}}"
    if (next != insets) {
      insets = next
      view.post { view.evaluateJavascript("window.dispatchEvent(new Event('shenzhen-insets'))", null) }
    }
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
