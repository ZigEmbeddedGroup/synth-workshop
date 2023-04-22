const std = @import("std");
const assert = std.debug.assert;
const EnumField = std.builtin.Type.EnumField;
const StructField = std.builtin.Type.StructField;

const microzig = @import("microzig");
const cpu = microzig.cpu;
const rp2040 = microzig.hal;
const clocks = rp2040.clocks;

pub const I2S = @import("i2s.zig").I2S;
pub const monitor = @import("monitor.zig");

pub fn GlitchFilter(comptime samples: usize) type {
    return packed struct {
        filter: std.meta.Int(.unsigned, samples),
        pressed: bool,

        const Self = @This();

        pub fn init() Self {
            return Self{
                .filter = 0,
                .pressed = false,
            };
        }

        pub fn update(self: *Self, sample: u1) void {
            self.filter <<= 1;
            self.filter |= sample;

            if (self.pressed and self.filter == 0)
                self.pressed = false
            else if (!self.pressed and @popCount(self.filter) == samples)
                self.pressed = true;
        }
    };
}

pub fn Volatile(comptime T: type) type {
    return struct {
        inner: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return Self{
                .inner = value,
            };
        }

        pub fn load(self: *volatile Self) T {
            return self.inner;
        }

        pub fn load_with_disabled_irqs(self: *volatile Self) T {
            cpu.disable_interrupts();
            defer cpu.enable_interrupts();

            return self.load();
        }

        pub fn store(self: *volatile Self, value: T) void {
            self.inner = value;
        }
    };
}

pub const SuperLoopOptions = struct {
    round_robin: bool = false,
};

pub fn SuperLoopFlags(comptime names: []const []const u8, comptime options: SuperLoopOptions) type {
    if (options.round_robin)
        @compileError("TODO round robin");

    var enum_fields: [names.len]std.builtin.Type.EnumField = undefined;
    var struct_fields: [names.len]std.builtin.Type.StructField = undefined;

    const flag_default = false;
    inline for (names, &enum_fields, &struct_fields, 0..) |name, *enum_field, *struct_field, i| {
        enum_field.* = EnumField{
            .name = name,
            .value = i,
        };

        struct_field.* = StructField{
            .name = name,
            .type = bool,
            .default_value = &flag_default,
            .is_comptime = false,
            .alignment = 1,
        };
    }

    const Enum = @Type(.{
        .Enum = .{
            .tag_type = u32,
            .fields = &enum_fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });

    const Flags = @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });

    return struct {
        flags: Flags = .{},
        const Self = @This();

        pub fn get(self: *volatile Self) ?Enum {
            microzig.cpu.disable_fault_irq();
            defer microzig.cpu.enable_fault_irq();

            return inline for (names) |name| {
                if (@field(self.flags, name)) {
                    @field(self.flags, name) = false;
                    break @field(Enum, name);
                }
            } else null;
        }

        /// only meant to be used by interrupt handlers
        pub fn set(self: *volatile Self, flag: Enum) void {
            //assert(cpu.executing_isr());

            inline for (names) |name| {
                if (flag == @field(Enum, name)) {
                    //if (@field(self.flags, name))
                    //    @panic("task flag still set")
                    //else
                    @field(self.flags, name) = true;
                }
            }
        }
    };
}

pub fn Oscillator(comptime sample_rate: u32) type {
    return struct {
        angle: u32,
        update_count: u32,

        const Self = @This();

        pub fn init(frequency: u32) Self {
            return Self{
                .angle = 0,
                .update_count = calculate_update_count(frequency),
            };
        }

        fn calculate_update_count(frequency: u32) u32 {
            return @intCast(u32, (@as(u64, 0x100000000) * frequency) / sample_rate);
        }

        pub fn update(self: *Self) void {
            self.angle +%= self.update_count;
        }

        pub fn set_frequency(tone: *Self, frequency: u32) void {
            tone.update_count = calculate_update_count(frequency);
        }
    };
}
