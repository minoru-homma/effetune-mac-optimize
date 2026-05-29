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
    ]
)
