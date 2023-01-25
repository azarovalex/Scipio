import Foundation
import PackageGraph
import TSCBasic

struct XcodeBuildCompiler<E: Executor>: Compiler {
    let rootPackage: Package
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem
    private let xcodebuild: XcodeBuildClient<E>
    private let extractor: DwarfExtractor<E>

    init(
        rootPackage: Package,
        buildOptions: BuildOptions,
        executor: E = ProcessExecutor(),
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
        self.fileSystem = fileSystem
        self.xcodebuild = XcodeBuildClient(executor: executor)
        self.extractor = DwarfExtractor(executor: executor)
    }

    func createXCFramework(
        buildProduct: BuildProduct,
        outputDirectory: URL,
        overwrite: Bool
    ) async throws {
        let buildConfiguration = buildOptions.buildConfiguration
        let sdks = extractSDKs(isSimulatorSupported: buildOptions.isSimulatorSupported)
        let target = buildProduct.target

        // Build frameworks for each SDK
        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        logger.info("📦 Building \(target.name) for \(sdkNames)")

        for sdk in sdks {
            try await xcodebuild.archive(package: rootPackage, target: target, buildConfiguration: buildConfiguration, sdk: sdk)
        }

        logger.info("🚀 Combining into XCFramework...")

        // If there is existing framework, remove it
        let frameworkName = target.xcFrameworkName
        let outputXCFrameworkPath = outputDirectory.appendingPathComponent(frameworkName)
        if fileSystem.exists(outputXCFrameworkPath) && overwrite {
            logger.info("🗑️ Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(at: outputXCFrameworkPath)
        }

        let debugSymbolPaths: [URL]?
        if buildOptions.isDebugSymbolsEmbedded {
            debugSymbolPaths = try await extractDebugSymbolPaths(target: target,
                                                                 buildConfiguration: buildConfiguration,
                                                                 sdks: sdks)
        } else {
            debugSymbolPaths = nil
        }

        // Combine all frameworks into one XCFramework
        try await xcodebuild.createXCFramework(
            package: rootPackage,
            buildProduct: buildProduct,
            buildConfiguration: buildConfiguration,
            sdks: sdks,
            debugSymbolPaths: debugSymbolPaths,
            outputDir: outputDirectory
        )
    }

    private func extractSDKs(isSimulatorSupported: Bool) -> Set<SDK> {
        if isSimulatorSupported {
            return Set(buildOptions.sdks.flatMap { $0.extractForSimulators() })
        } else {
            return Set(buildOptions.sdks)
        }
    }
}

extension Package {
    var archivesPath: URL {
        workspaceDirectory.appendingPathComponent("archives")
    }
}
