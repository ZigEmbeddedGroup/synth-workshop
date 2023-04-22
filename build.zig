const std = @import("std");
const Builder = std.build.Builder;

const rp2040 = @import("deps/raspberrypi-rp2040/build.zig");
const uf2 = @import("deps/uf2/src/main.zig");

const demos: []const []const u8 = &.{
    "demos/blinky.zig",
    "demos/uart.zig",
    "demos/single_tone.zig",
};

pub fn build(b: *Builder) void {
    const optimize = b.standardOptimizeOption(.{});

    for (demos) |demo_path| {
        const workshop_module = b.createModule(.{
            .source_file = .{
                .path = "src/workshop.zig",
            },
        });
        const exe = rp2040.addPiPicoExecutable(b, .{
            .name = std.mem.trim(u8, std.fs.path.basename(demo_path), ".zig"),
            .source_file = .{
                .path = demo_path,
            },
            .optimize = optimize,
        });
        exe.addAppDependency("workshop", workshop_module, .{
            .depend_on_microzig = true,
        });
        exe.installArtifact(b);

        const uf2_step = uf2.Uf2Step.create(exe.inner, .{ .family_id = .RP2040 });
        uf2_step.install();
    }
}
