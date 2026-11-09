import Foundation
import Testing

@main struct TestEntry {
    static func main() async {
        let code: CInt = await Testing.__swiftPMEntryPoint()
        exit(code)
    }
}
