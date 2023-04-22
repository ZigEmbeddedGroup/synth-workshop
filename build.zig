const std = @import("std");
const builtin = @import("builtin");
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

    // tools
    const os_str = comptime enum_to_string(builtin.os.tag);
    const arch_str = comptime enum_to_string(builtin.cpu.arch);

    // openocd
    const openocd_subdir = comptime std.fmt.comptimePrint("tools/openocd/{s}-{s}", .{ arch_str, os_str });
    const openocd_scripts_dir = comptime project_root(std.fmt.comptimePrint("{s}/share/openocd/scripts", .{openocd_subdir}));
    const openocd_exe = comptime project_root(std.fmt.comptimePrint("{s}/bin/openocd{s}", .{
        openocd_subdir,
        if (builtin.os.tag == .windows) ".exe" else "",
    }));

    // zig fmt: off
    const run_openocd = b.addSystemCommand(&.{
        openocd_exe,
        "-s", openocd_scripts_dir,
        "-f", "interface/cmsis-dap.cfg",
        "-f", "target/rp2040.cfg",
        "-c", "adapter speed 5000",
    });
    // zig fmt: on

    const openocd = b.step("openocd", "run openocd for your debugger");
    openocd.dependOn(&run_openocd.step);
}

fn project_root(comptime path: []const u8) []const u8 {
    const root_dir = std.fs.path.dirname(@src().file) orelse unreachable;
    return std.fmt.comptimePrint("{s}/{s}", .{ root_dir, path });
}

fn enum_to_string(comptime val: anytype) []const u8 {
    const Enum = @TypeOf(val);
    return inline for (@typeInfo(Enum).Enum.fields) |field| {
        if (val == @field(Enum, field.name))
            break field.name;
    } else unreachable;
}
