# WebRTC: классы и методы вызываются из нативной библиотеки по именам
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# BouncyCastle (X25519/Ed25519 в ядре)
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# flutter_secure_storage (вендорный Java-код хранилища ключей)
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# OkHttp/Okio тянут необязательные платформы
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
