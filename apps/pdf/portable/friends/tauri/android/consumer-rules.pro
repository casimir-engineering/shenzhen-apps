# Tauri finds the plugins' commands and argument classes by reflection.
-keep class com.shenzhen.friends.FriendsPlugin { *; }
-keep @app.tauri.annotation.InvokeArg class com.shenzhen.friends.** { *; }
-keep class app.shenzhen.friends.nearby.NearbyPlugin { *; }
-keep @app.tauri.annotation.InvokeArg class app.shenzhen.friends.nearby.** { *; }
# The platform calls BluetoothGattCallback.onConnectionUpdated, hidden from the SDK, so R8 cannot see it is an override.
-keepclassmembers class app.shenzhen.friends.nearby.** extends android.bluetooth.BluetoothGattCallback {
    public void onConnectionUpdated(android.bluetooth.BluetoothGatt, int, int, int, int);
}
