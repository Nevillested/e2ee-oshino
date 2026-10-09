// Нативный Kotlin-клиент Oshinobu — постепенная замена Flutter-клиента
// (../client). Пока не достигнут паритет функций, в Google Play продолжает
// уходить Flutter-сборка; эта — параллельно, ставится поверх неё с тем же
// applicationId и читает её данные (ключи, сессии, переписку).
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "oshinobu-kotlin"

// :core — чистый Kotlin/JVM без Android: криптография (X3DH, Double Ratchet,
// шифрование сообщений и файлов) и формат конвертов. Собирается и
// тестируется на любой машине с JDK, без Android SDK.
include(":core")

// :flutter-compat — Android: SecureStore/Prefs/AppDirs поверх тех же файлов,
// что пишет Flutter-клиент (код flutter_secure_storage, FlutterSharedPreferences).
include(":flutter-compat")

// :app — само Android-приложение (Jetpack Compose).
include(":app")
