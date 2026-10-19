package com.shenzhen3d.viewer

import android.graphics.Color
import android.os.Bundle
import android.view.View
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

class MainActivity : TauriActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    val background = Color.rgb(20, 29, 33)
    enableEdgeToEdge(
      statusBarStyle = SystemBarStyle.dark(background),
      navigationBarStyle = SystemBarStyle.dark(background)
    )
    super.onCreate(savedInstanceState)
    window.decorView.setBackgroundColor(background)
    // Android WebView does not reliably expose the enforced Android 15+ system
    // bar insets through CSS env(). Keep all viewer controls inside the safe area.
    val content = findViewById<View>(android.R.id.content)
    ViewCompat.setOnApplyWindowInsetsListener(content) { view, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
      view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
      insets
    }
    ViewCompat.requestApplyInsets(content)
  }
}
