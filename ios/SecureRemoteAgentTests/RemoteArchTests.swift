import Testing
@testable import SecureRemoteAgent

@Suite("RemoteArch parsing")
struct RemoteArchTests {
    @Test func darwinArm64() {
        #expect(RemoteArch.parse(uname: "Darwin arm64") == .darwinArm64)
    }
    @Test func linuxX64() {
        #expect(RemoteArch.parse(uname: "Linux x86_64") == .linuxX64)
    }
    @Test func linuxArm64() {
        #expect(RemoteArch.parse(uname: "Linux aarch64") == .linuxArm64)
    }
    @Test func harnessNames() {
        #expect(RemoteArch.darwinArm64.harnessResourceName == "harness-darwin-arm64")
        #expect(RemoteArch.linuxX64.harnessResourceName == "harness-linux-x64")
    }
}
