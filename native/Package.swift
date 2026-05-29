// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EffeTuneNative",
    platforms: [.macOS(.v13)],
    targets: [
        // Engine: dlopen loader for the Rust DSP dylibs, RT-safe effect chain,
        // and the CoreAudio AUHAL realtime I/O engine.
        .target(
            name: "EffeTuneEngine",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Headless verifier: render a known signal through a chain of native
        // effects offline and report peak/RMS. Runs without audio devices.
        .executableTarget(
            name: "dsptest",
            dependencies: ["EffeTuneEngine"]
        ),
        // The macOS app: AppKit window hosting a WKWebView with the EffeTune UI,
        // bridged to the native CoreAudio engine. Bundled into EffeTune.app by
        // native/app/make-app.sh.
        .executableTarget(
            name: "EffeTuneApp",
            dependencies: ["EffeTuneEngine"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
            ]
        ),
    ]
)
