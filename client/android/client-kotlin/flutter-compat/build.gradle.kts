// Хранилища приложения на Android в унаследованном формате первой версии
// клиента (на нём лежат ключи и переписка всех установленных копий).
//
// src/main/java/com/it_nomads/** — вендорные исходники flutter_secure_storage
// 10.3.1 (BSD-3, см. LICENSE-flutter_secure_storage), без плагинной обёртки.
// Пакет и имена классов НЕ менять — от них зависят имена файлов и ключей
// Keystore. Самого Flutter в проекте нет.
plugins {
    id("com.android.library")
    kotlin("android")
}

android {
    namespace = "com.it_nomads.fluttersecurestorage"
    compileSdk = 36
    defaultConfig {
        minSdk = 24
    }
    buildFeatures {
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    api(project(":core"))
    implementation("com.google.crypto.tink:tink-android:1.21.0")
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("androidx.collection:collection:1.5.0")
}
