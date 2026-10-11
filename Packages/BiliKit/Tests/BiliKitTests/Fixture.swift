import Foundation

/// Loads test fixtures both from SwiftPM (`Bundle.module`) and the XcodeGen test bundle.
enum Fixture {
    private final class Token {}

    static func data(_ name: String) -> Data {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module]
        #else
        let bundles = [Bundle(for: Token.self)]
        #endif
        let (base, ext) = ((name as NSString).deletingPathExtension, (name as NSString).pathExtension)
        for bundle in bundles {
            for subdir in ["Fixtures", nil] as [String?] {
                if let url = bundle.url(forResource: base, withExtension: ext, subdirectory: subdir),
                   let data = try? Data(contentsOf: url)
                {
                    return data
                }
            }
        }
        fatalError("missing fixture \(name)")
    }
}
