// Zig 0.17.x (pinned: 0.14/0.15 toolchains cannot link on current macOS;
// 0.17 reworked std.io — this harness uses the new Io/Threaded APIs.)
const std = @import("std");

pub fn build(b: *std.Build) void {
    // Honor `-Dtarget=` so scripts/build-harness.sh can cross-compile the
    // four shipped remotes from one macOS host. Default target = host.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        // Default to ReleaseSmall: priority is compiled program size
        // for the embedded remote harnesses shipped inside the iOS bundle.
        .preferred_optimize_mode = .ReleaseSmall,
    });

    const exe = b.addExecutable(.{
        .name = "secure-remote-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Size-first knobs:
            // - single_threaded where possible (no thread pool bloat)
            // - strip debug info, omit frame pointers in ReleaseSmall
            .single_threaded = true,
            .strip = true,
        }),
    });

    // `zig build`            -> host binary in zig-out/bin
    // `zig build -Doptimize=ReleaseSmall` (default) keeps it tiny.
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the harness (stdio ACP)");
    run_step.dependOn(&run_cmd.step);

    // Unit tests: `zig build test`
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
