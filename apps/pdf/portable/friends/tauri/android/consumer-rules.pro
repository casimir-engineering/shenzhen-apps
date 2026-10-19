# Tauri finds the plugins' commands and argument classes by reflection.
-keep class com.shenzhen.friends.FriendsPlugin { *; }
-keep @app.tauri.annotation.InvokeArg class com.shenzhen.friends.** { *; }
-keep class app.shenzhen.friends.nearby.NearbyPlugin { *; }
-keep @app.tauri.annotation.InvokeArg class app.shenzhen.friends.nearby.** { *; }
