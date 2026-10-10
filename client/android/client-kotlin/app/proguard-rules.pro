# WebRTC: классы и методы вызываются из нативной библиотеки по именам
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**
# JNI-мост WebRTC: JNI_OnLoad ищет эти классы по именам, без них — нативный краш при первом звонке
-keep class org.jni_zero.** { *; }
-dontwarn org.jni_zero.**

# BouncyCastle (X25519/Ed25519 в ядре)
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# flutter_secure_storage (вендорный Java-код хранилища ключей)
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# OkHttp/Okio тянут необязательные платформы
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
