group = "dev.flowdroid.phone_bridge"
version = "1.0"

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.flowdroid.phone_bridge"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // FileProvider: opening and sharing files from workflows with other apps.
    implementation("androidx.core:core:1.13.1")
    // Photo & Scan: Google's document scanner (edge detection, cleanup, PDF), run by Play services.
    implementation("com.google.android.gms:play-services-mlkit-document-scanner:16.0.0")
}
