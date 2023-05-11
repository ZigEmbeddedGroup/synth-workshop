const std = @import("std");
const assert = std.debug.assert;
const EnumField = std.builtin.Type.EnumField;
const StructField = std.builtin.Type.StructField;

const microzig = @import("microzig");
const cpu = microzig.cpu;
const rp2040 = microzig.hal;
const clocks = rp2040.clocks;
const gpio = rp2040.gpio;
const time = rp2040.time;

pub const I2S = @import("i2s.zig").I2S;
pub const monitor = @import("monitor.zig");
pub const notes = @import("notes.zig");

pub fn GlitchFilter(comptime samples: usize) type {
    return packed struct {
        filter: FilterInt,
        state: bool,

        const Self = @This();
        pub const FilterInt = std.meta.Int(.unsigned, samples);

        pub fn init() Self {
            return Self{
                .filter = 0,
            };
        }

        /// Update the glitch filter with a new sample. If the state
        /// changes, then return it, otherwise null.
        pub fn update(self: *Self, sample: u1) ?bool {
            self.filter <<= 1;
            self.filter |= sample;

            return if (self.state and self.filter == 0) blk: {
                self.state = false;
                break :blk self.state;
            } else if (!self.state and self.filter == std.math.maxInt(FilterInt)) blk: {
                self.state = true;
                break :blk self.state;
            } else null;
        }
    };
}

pub fn Encoder(comptime samples: usize) type {
    return struct {
        a: GlitchFilter(samples),
        b: GlitchFilter(samples),

        const Self = @This();

        pub const Result = enum {
            increment,
            decrement,
        };

        pub fn init() Self {
            return Self{
                .a = GlitchFilter(samples).init(),
                .b = GlitchFilter(samples).init(),
            };
        }

        pub fn update(self: *Self, sample: struct {
            a: u1,
            b: u1,
        }) ?Result {
            var result: Result = null;
            if (self.glitch.a.update(sample.a)) |new_state_a| {
                result = if (new_state_a ^ self.glitch.b.state)
                    .decrement
                else
                    .increment;
            }

            if (self.glitch.b.update(sample.b)) |new_state_b| {
                // if result has already been set then both channels have had a
                // state change. If you consider the transitions to happen at
                // the exact same time, then we're seeing both an increment and
                // a decrement, so we'll consider them to have cancelled out,
                // and set the result to null.
                //
                // In actuality the filters are operating at their limits, the
                // number of samples likely need tuning, or the sample rate.
                // There are other methods we could use to improve performance
                // but they add complexity.
                result = if (result != null)
                    null
                else if (new_state_b ^ self.glitch.a.state)
                    .increment
                else
                    .decrement;
            }

            return result;
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

pub fn update_count_from_float(sample_rate: u32, frequency: f32) u32 {
    return @floatToInt(
        u32,
        frequency / @intToFloat(f32, sample_rate) * std.math.pow(f32, 2, 32),
    );
}

/// The oscillator takes advantage of integer overflow to represent radians as
/// you rotate about a circle. It assumes 32-bit architecture so that maximum
/// precision is achieved with minimum runtime cost.
///
/// The sample rate is known at compile time, and the frequency can be changed
/// at runtime.
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

        pub fn tick(self: *Self) void {
            self.angle +%= self.update_count;
        }

        pub fn set_frequency(self: *Self, frequency: u32) void {
            self.update_count = calculate_update_count(frequency);
        }

        /// at compile time,
        pub fn set_frequency_float(self: *Self, comptime frequency: f32) void {
            self.update_count = comptime update_count_from_float(frequency);
        }

        pub fn to_sawtooth(self: Self, comptime T: type) T {
            assert(std.meta.trait.isSignedInt(T));

            const UnsignedSample = std.meta.Int(.unsigned, @bitSizeOf(T));
            return @bitCast(T, @truncate(
                UnsignedSample,
                self.angle >> 32 - @bitSizeOf(T),
            ));
        }
    };
}

// TODO: why must these be backwards?
pub const Coordinate = packed struct(u4) {
    col: u2,
    row: u2,
};

/// Can be binary cast to and from coordinates
pub const Button = enum(u4) {
    one = 0x0,
    two = 0x1,
    three = 0x2,
    a = 0x3,

    four = 0x4,
    five = 0x5,
    six = 0x6,
    b = 0x7,

    seven = 0x8,
    eight = 0x9,
    nine = 0xa,
    c = 0xb,

    star = 0xc,
    zero = 0xd,
    pound = 0xe,
    d = 0xf,

    pub fn from_coord(coord: Coordinate) Button {
        return @intToEnum(Button, @bitCast(u4, coord));
    }
};

const Event = packed struct {
    kind: enum {
        press,
        release,
    },
    button: struct {
        row: u8,
        col: u8,
    },
};

fn CircularBuffer(comptime T: type, comptime size: usize) type {
    return struct {
        start: usize,
        len: usize,
        items: [size]T,

        const Self = @This();

        pub fn init() Self {
            return Self{
                .start = 0,
                .len = 0,
                .items = undefined,
            };
        }
    };
}

pub fn Keypad(comptime options: struct {
    row_pins: [4]u5,
    col_pins: [4]u5,
    period_us: u32,
}) type {
    const rows_mask = blk: {
        var result: u32 = 0;
        inline for (options.row_pins) |pin|
            result |= @as(u32, 1) << pin;

        break :blk result;
    };

    const cols_mask = blk: {
        var result: u32 = 0;
        inline for (options.col_pins) |pin|
            result |= @as(u32, 1) << pin;

        break :blk result;
    };

    assert(0 == rows_mask & cols_mask); // NO OVERLAP

    return struct {
        order: OrderList,
        pressed: [4][4]bool,
        deadline: time.Absolute,
        row: u2,

        const Self = @This();

        const OrderList = std.BoundedArray(Button, options.row_pins.len * options.col_pins.len);
        const rows = gpio.mask(rows_mask);
        const cols = gpio.mask(cols_mask);

        pub fn init() Self {
            cols.set_function(.sio);
            cols.set_direction(.in);
            cols.set_pull(.down);

            // we scan by rows, so they are the outputs
            rows.set_function(.sio);
            rows.set_direction(.out);

            return Self{
                .order = OrderList.init(0) catch unreachable,
                .pressed = .{[_]bool{false} ** 4} ** 4,
                .deadline = time.make_timeout_us(options.period_us / 4),
                .row = 0,
            };
        }

        pub fn tick(self: *Self) void {
            if (self.deadline.reached()) {
                const result = cols.read();
                for (options.col_pins, 0..) |pin, col| {
                    const pressed = &self.pressed[self.row][col];
                    if (0 != result & (@as(u32, 1) << pin)) {
                        // don't do anything if it's already pressed
                        if (pressed.*)
                            continue;

                        pressed.* = true;

                        // this is unreachable because it should never
                        // overflow. We treat it as an ordered set of pressed
                        // buttons.
                        self.order.append(Button.from_coord(.{
                            .row = self.row,
                            .col = @intCast(u2, col),
                        })) catch unreachable;
                    } else if (pressed.*) {
                        // the button was then released, remove it from the list
                        pressed.* = false;
                        const button = Button.from_coord(.{
                            .row = self.row,
                            .col = @intCast(u2, col),
                        });
                        const index = std.mem.indexOf(Button, self.order.slice(), &.{button}).?;
                        _ = self.order.orderedRemove(index);
                    }
                }

                self.row +%= 1;
                rows.put(@as(u32, 1) << options.row_pins[self.row]);
                self.deadline = time.make_timeout_us(options.period_us / 4);
            }
        }

        pub fn get_pressed(self: *Self) ?Button {
            return if (self.order.len != 0)
                self.order.buffer[self.order.len - 1]
            else
                null;
        }
    };
}
