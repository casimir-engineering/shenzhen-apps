package com.shenzhen3d.viewer

import android.net.Uri
import android.util.Log
import android.webkit.WebView
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.util.concurrent.Executors

private const val TAG = "ShenzhenIpc"

/**
 * The page's calls into the app (`window.ipc.postMessage`), each sent with the address of the page that made it.
 *
 * wry, the WebView layer under Tauri, sends every call with the page address its RustWebViewClient last recorded in
 * onPageStarted, which runs on the main thread, and with "about:blank" before that. While the main thread is busy as
 * a page loads (the first launch after an update, or the activity being created again on return from Android's
 * installer or Settings), the page's first calls can go out before onPageStarted has run. Tauri then takes them for a
 * remote page's, which no capability covers, and refuses them: the page showed "Command plugin:event|listen not
 * allowed by ACL". Here each call carries the origin Chromium reports for its sender instead, as wry does from its
 * next release (tauri-apps/wry#1891, unreleased after 0.57.1). Remove this file once Cargo.lock has a wry with it.
 *
 * Installed from MainActivity.onWebViewCreate, posted so it runs after wry has added its own "ipc" object and before
 * the first page loads (wry posts that load after the hook returns).
 */
internal object PageIpc {
  /** In order, off the main thread: Tauri may wait on the main thread while it handles a call. */
  private val sender = Executors.newSingleThreadExecutor()

  fun install(view: WebView) {
    val page = view as? RustWebView ?: return
    if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
      Log.i(TAG, "this WebView reports no sender origin; wry's IPC stays as it is")
      return
    }
    try {
      WebViewCompat.addWebMessageListener(page, "ipc", setOf("*")) { from, message, origin, isMainFrame, _ ->
        // getData throws for ArrayBuffer messages; Tauri sends strings.
        val body = try { message.data } catch (e: IllegalStateException) { null } ?: return@addWebMessageListener
        val url = requestUrl(origin, isMainFrame, from.url)
        sender.execute { Rust.ipc(page.id, url, body) }
      }
    } catch (error: RuntimeException) {
      // A wry that already listens as "ipc" does this itself; nothing has changed, its IPC stays.
      Log.w(TAG, "could not listen for the page's calls; wry's own IPC stays", error)
      return
    }
    // wry's interface of the same name goes; both take effect with the first page, which loads after this.
    page.removeJavascriptInterface("ipc")
  }

  /**
   * The page's URL for calls from the main frame when it is on the sender's origin, else the sender's origin; an
   * opaque origin (no host) gives about:blank, which Tauri trusts with nothing.
   */
  internal fun requestUrl(origin: Uri, isMainFrame: Boolean, pageUrl: String?): String {
    if (origin.host == null) return "about:blank"
    // WebView.getUrl can already name a navigation still pending while the previous page sends, so it counts only
    // when it is on the sender's origin.
    val page = if (isMainFrame) pageUrl?.let(Uri::parse) else null
    if (page != null && page.scheme == origin.scheme && page.host == origin.host && page.port == origin.port) {
      return page.toString()
    }
    return origin.buildUpon().path("/").build().toString()
  }
}
