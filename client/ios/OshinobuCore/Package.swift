// swift-tools-version:5.9
import PackageDescription

// Ядро iOS-клиента: криптография (CryptoKit), протокол, сеть, хранилища, сервисы.
// Без UIKit/SwiftUI — собирается и тестируется отдельно от приложения (Oshinobu/).
// Формат на проводе — тот же, что у Android (client/android/client-kotlin/core),
// его сторожат векторы Tests/OshinobuCoreTests/Resources/protocol_transcript.json.
let package = Package(
    name: "OshinobuCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OshinobuCore", targets: ["OshinobuCore"]),
    ],
    targets: [
        .target(name: "OshinobuCore", path: "Sources/OshinobuCore"),
        .testTarget(
            name: "OshinobuCoreTests",
            dependencies: ["OshinobuCore"],
            path: "Tests/OshinobuCoreTests",
            resources: [.copy("Resources")]
        ),
    ]
)
