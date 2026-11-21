import Foundation
import Testing
@testable import SecureRemoteAgent

@Suite("HarnessDeployer helpers")
struct HarnessDeployerTests {
    @Test func sha256MatchesNistVector() {
        // "abc" — FIPS 180-4.
        let hex = HarnessDeployer.sha256Hex(of: Data("abc".utf8))
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func sha256DistinguishesInputs() {
        #expect(HarnessDeployer.sha256Hex(of: Data("a".utf8))
            != HarnessDeployer.sha256Hex(of: Data("b".utf8)))
    }

    @Test func fileNameIsVersioned() {
        #expect(HarnessDeployer.fileName(for: .darwinArm64) == "harness-darwin-arm64-0.1.0")
        #expect(HarnessDeployer.fileName(for: .linuxX64) == "harness-linux-x64-0.1.0")
    }

    @Test func staleEntriesKeepsCurrentAndOthers() {
        let listing = """
            harness-darwin-arm64-0.0.9
            harness-darwin-arm64-0.1.0
            harness-linux-x64-0.1.0
            notes.txt
            """
        let stale = HarnessDeployer.staleEntries(
            lsOutput: listing, arch: .darwinArm64,
            current: "harness-darwin-arm64-0.1.0")
        #expect(stale == ["harness-darwin-arm64-0.0.9"])
    }

    @Test func staleEntriesEmptyWhenClean() {
        #expect(HarnessDeployer.staleEntries(
            lsOutput: "harness-linux-x64-0.1.0\n", arch: .linuxX64,
            current: "harness-linux-x64-0.1.0") == [])
        #expect(HarnessDeployer.staleEntries(lsOutput: "", arch: .linuxX64,
            current: "harness-linux-x64-0.1.0") == [])
    }

    @Test func staleEntriesRejectsTraversal() {
        // A hostile `ls` line must never become an `rm` argument.
        let listing = "harness-linux-x64-0.0.1\n../../evil"
        let stale = HarnessDeployer.staleEntries(
            lsOutput: listing, arch: .linuxX64,
            current: "harness-linux-x64-0.1.0")
        #expect(stale == ["harness-linux-x64-0.0.1"])
    }
}
