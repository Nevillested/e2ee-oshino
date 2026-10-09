plugins {
    id("com.android.application")
    kotlin("android")
    kotlin("plugin.compose")
    // пуши (FCM): google-services.json — тот же проект Firebase, что у Flutter-клиента
    id("com.google.gms.google-services")
}

android {
    namespace = "com.oshinobu.app"
    compileSdk = 36

    defaultConfig {
        // тот же applicationId, что у Flutter-сборки: ставится поверх неё и
        // работает с её данными (см. :flutter-compat)
        applicationId = "com.oshinobu.oshinobu_client"
        minSdk = 23
        targetSdk = 36
        versionCode = providers.gradleProperty("oshinobu.versionCode").get().toInt()
        versionName = providers.gradleProperty("oshinobu.versionName").get()
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        // та же оптимизированная сборка, но с отладочной подписью — ставится поверх
        // debug-сборки, чтобы оценить настоящую скорость (debug в разы медленнее)
        create("profile") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += listOf("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
    }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1,INDEX.LIST,DEPENDENCIES}"
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":core"))
    implementation(project(":flutter-compat"))

    implementation(platform("androidx.compose:compose-bom:2025.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.exifinterface:exifinterface:1.4.1")
    implementation(platform("com.google.firebase:firebase-bom:33.16.0"))
    implementation("com.google.firebase:firebase-messaging")
    // обновление из Google Play прямо в приложении
    implementation("com.google.android.play:app-update-ktx:2.1.0")
    // разблокировка приложения отпечатком/лицом
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.1")
    implementation("androidx.lifecycle:lifecycle-process:2.9.1")
    implementation("androidx.navigation:navigation-compose:2.9.0")
    // звонки: тот же WebRTC, что под flutter_webrtc 1.6.0 у Flutter-клиента
    implementation("io.github.webrtc-sdk:android:144.7559.09")
    // запись видео-кружков
    implementation("androidx.camera:camera-core:1.4.2")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-video:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
    // QR-код для подключения приложения-аутентификатора (TOTP)
    implementation("com.google.zxing:core:3.5.3")
}
