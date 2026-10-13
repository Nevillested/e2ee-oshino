// Android-клиент Oshinobu (Kotlin).
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

// :flutter-compat — Android: SecureStore/Prefs/AppDirs. Формат файлов унаследован
// от первой версии клиента (flutter_secure_storage, FlutterSharedPreferences) и
// не меняется — на нём данные установленных копий; самого Flutter в проекте нет.
include(":flutter-compat")

// :app — само Android-приложение (Jetpack Compose).
include(":app")
