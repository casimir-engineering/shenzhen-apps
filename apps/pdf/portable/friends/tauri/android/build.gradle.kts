// The Kotlin half of tauri-plugin-szfriends (ADR 0015 § 7, § 9, § 10, § 17): the Keystore that seals the Friends
// key, the no-backup directory, the share sheet, links and settings screens (FriendsPlugin), and nearby discovery
// with NsdManager and Bluetooth LE with L2CAP channels (nearby/, src/nearby.rs). Built into the host app by Tauri,
// which puts its own library in .tauri/tauri-api.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.shenzhen.friends"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_1_8
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.9.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation(project(":tauri-android"))
}
