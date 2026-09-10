// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VozLivre",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        // Cabeçalhos do whisper.cpp expostos ao Swift. As bibliotecas estáticas são
        // geradas por scripts/preparar.sh em Vendor/whisper-lib/lib.
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "VozLivre",
            dependencies: ["CWhisper"],
            path: "Sources/VozLivre",
            linkerSettings: [
                // Embute o Info.plist no binário (LSUIElement + NSMicrophoneUsageDescription).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                    // Motor de transcrição embutido no processo.
                    "-LVendor/whisper-lib/lib",
                    "-lwhisper", "-lggml", "-lggml-base", "-lggml-cpu",
                    "-lggml-blas", "-lggml-metal", "-lc++"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        // Banco de provas do motor: transcreve um WAV e reporta os tempos reais.
        .executableTarget(
            name: "TesteMotor",
            dependencies: ["CWhisper"],
            path: "Sources/TesteMotor",
            linkerSettings: [
                .unsafeFlags([
                    "-LVendor/whisper-lib/lib",
                    "-lwhisper", "-lggml", "-lggml-base", "-lggml-cpu",
                    "-lggml-blas", "-lggml-metal", "-lc++"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
