plugins {
    kotlin("jvm")
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // X25519 / Ed25519 (RFC 7748 / RFC 8032) — чистая Java, работает и на
    // JVM, и на Android. AES-GCM/HMAC берём из javax.crypto (на Android —
    // аппаратный AES).
    implementation("org.bouncycastle:bcprov-jdk18on:1.81")
    // Только JsonElement-API, без @Serializable — компиляторный плагин не нужен.
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    // сеть: REST и WebSocket (net/ApiClient.kt, net/WebSocketClient.kt)
    api("com.squareup.okhttp3:okhttp:4.12.0")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")

    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.13.4")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}

tasks.test {
    useJUnitPlatform()
}
