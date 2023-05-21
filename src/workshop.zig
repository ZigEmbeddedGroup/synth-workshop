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

pub fn apply_volume(sample: anytype, volume: u12) @TypeOf(sample) {
    const Sample = @TypeOf(sample);
    comptime assert(std.meta.trait.isSignedInt(Sample));

    const product = std.math.mulWide(Sample, sample, volume);
    return @intCast(Sample, product >> 12);
}

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

pub fn update_count_from_float(sample_rate: u32, frequency: f64) u32 {
    return @floatToInt(
        u32,
        frequency / @intToFloat(f64, sample_rate) * std.math.pow(f64, 2, 32),
    );
}

/// The oscillator takes advantage of integer overflow to represent radians as
/// you rotate about a circle. It assumes 32-bit architecture so that maximum
/// precision is achieved with minimum runtime cost.
///
/// The sample rate is known at compile time, and the frequency can be changed
/// at runtime.
/// TODO: remove comptime param
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

        pub fn reset(self: *Self) void {
            self.angle = 0;
            self.update_count = 0;
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
            comptime assert(std.meta.trait.isSignedInt(T));

            const UnsignedSample = std.meta.Int(.unsigned, @bitSizeOf(T));
            return @bitCast(T, @truncate(
                UnsignedSample,
                self.angle >> 32 - @bitSizeOf(T),
            ));
        }

        pub fn to_squarewave(self: Self, comptime T: type) T {
            comptime assert(std.meta.trait.isSignedInt(T));

            return if (self.update_count != 0)
                if (self.angle > (std.math.maxInt(u32) / 2))
                    std.math.maxInt(T)
                else
                    std.math.minInt(T)
            else
                0;
        }

        pub fn to_sine(self: Self, comptime T: type) T {
            comptime assert(std.meta.trait.isSignedInt(T));
            const lut = comptime blk: {
                const samples = 32;

                assert(std.math.isPowerOfTwo(samples));
                var ret: [samples]T = undefined;
                const radian_delta = (2.0 * std.math.pi) / @intToFloat(comptime_float, samples);

                for (0..samples) |i|
                    ret[i] = @floatToInt(T, @intToFloat(f64, std.math.maxInt(T)) * @sin(@intToFloat(f64, i) * radian_delta));

                break :blk ret;
            };

            const lut_bits = comptime std.math.log2(lut.len);
            const LutIndex = std.meta.Int(.unsigned, lut_bits);
            const x_span = comptime 1 << (32 - lut_bits);

            const y0_index: LutIndex = @intCast(LutIndex, self.angle >> @as(u5, 32 - lut_bits));
            const y1_index = y0_index +% 1;

            const y0 = lut[y0_index];
            const y1 = lut[y1_index];

            const x0 = @as(u32, y0_index) * x_span;

            const y_span = y1 - y0;

            const x_delta = @intCast(i32, self.angle - x0);
            // TODO: fix overflow here
            const y = y0 + @divFloor(std.math.mulWide(i32, x_delta, y_span), x_span);

            return @intCast(T, y);
        }
    };
}

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

pub fn CircularDoubleBuffer(comptime T: type, comptime size: usize) type {
    return struct {
        start: usize,
        len: usize,
        buffer: [2 * size]T,

        const Self = @This();

        pub fn init() Self {
            return Self{
                .start = 0,
                .len = 0,
                .items = undefined,
            };
        }

        pub fn const_slice(self: *const Self) []const T {
            return self.buffer[self.start..self.len];
        }

        pub fn append(self: *Self, item: T) !void {
            if (self.len >= size)
                return error.NoSpace;

            self.buffer[self.start + self.len] = item;
            self.buffer[(self.start + self.len + size) % self.buffer.len] = item;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            return if (self.len > 0) blk: {
                defer {
                    if (self.start == size - 1)
                        self.start = 0
                    else
                        self.start += 1;

                    self.len -= 1;
                }

                break :blk self.buffer[self.start];
            } else null;
        }
    };
}

pub const ButtonState = enum(u1) {
    pressed,
    released,
};

pub const KeypadEvent = struct {
    timestamp: time.Absolute,
    kind: ButtonState,
    button: Button,
};

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
        pressed: [16]bool,
        timestamps: [16]time.Absolute,
        last_released: ?Button,
        deadline: time.Absolute,
        row: u2,
        state_changed: bool,

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
                .pressed = [_]bool{false} ** 16,
                .timestamps = [_]time.Absolute{@intToEnum(time.Absolute, 0)} ** 16,
                .last_released = null,
                .deadline = time.make_timeout_us(options.period_us / 4),
                .row = 0,
                .state_changed = false,
            };
        }

        pub fn tick(self: *Self) void {
            if (self.deadline.reached()) {
                const result = cols.read();
                for (options.col_pins, 0..) |pin, col| {
                    const button = Button.from_coord(.{
                        .row = self.row,
                        .col = @intCast(u2, col),
                    });

                    // detect that state has changed
                    const prev = self.pressed[@enumToInt(button)];
                    const curr = (0 != result & (@as(u32, 1) << pin));

                    // no state change detected, continue to the next button in
                    // the row
                    if (prev == curr)
                        continue;

                    if (curr) { // pressed
                        if (self.last_released) |released_button| {
                            if (button == released_button)
                                self.last_released = null;
                        }

                        self.order.append(button) catch unreachable;
                        self.pressed[@enumToInt(button)] = true;
                    } else { // released
                        const index = std.mem.indexOfScalar(Button, self.order.slice(), button).?;
                        _ = self.order.orderedRemove(index);
                        self.last_released = button;
                        self.pressed[@enumToInt(button)] = false;
                    }

                    // update timestamp to last state update
                    self.timestamps[@enumToInt(button)] = time.get_time_since_boot();
                    self.state_changed = true;
                }

                self.row +%= 1;
                rows.put(@as(u32, 1) << options.row_pins[self.row]);
                self.deadline = time.make_timeout_us(options.period_us / 4);
            }
        }

        pub fn get_event(self: *Self) ?KeypadEvent {
            return if (self.state_changed) event: {
                defer self.state_changed = false;
                const kind: ButtonState = if (self.order.len > 0)
                    .pressed
                else
                    .released;

                const button = switch (kind) {
                    .pressed => self.order.get(self.order.len - 1),
                    .released => self.last_released.?,
                };

                break :event KeypadEvent{
                    .kind = kind,
                    .button = button,
                    .timestamp = self.timestamps[@enumToInt(button)],
                };
            } else null;
        }
    };
}

pub fn mix(
    comptime T: type,
    /// levels are arbitrary weights, they are normalized so that their sum is 1.0
    comptime levels: []const f64,
    inputs: [levels.len]T,
) T {
    comptime assert(std.meta.trait.isSignedInt(T));
    const weights = comptime weights: {
        for (levels) |level|
            assert(level >= 0.0); // levels must be positive

        const scale = blk: {
            var acc: f64 = 0.0;
            for (levels) |level|
                acc += level;

            break :blk 1.0 / acc;
        };

        var float_weights: [levels.len]f64 = undefined;
        for (&float_weights, levels) |*fw, level|
            fw.* = scale * level;

        var fixed_weights: [levels.len]T = undefined;
        for (float_weights, 0..) |float, i|
            fixed_weights[i] = @floatToInt(T, std.math.round(@intToFloat(f64, std.math.maxInt(T)) * float));

        const sum = blk: {
            var ret: T = 0;
            for (0..levels.len) |i| {
                const result = @addWithOverflow(ret, fixed_weights[i]);
                if (result[1] == 1)
                    fixed_weights[i] -= 1;

                ret += fixed_weights[i];
            }

            break :blk ret;
        };

        assert(sum == std.math.maxInt(T));
        break :weights fixed_weights;
    };

    const acc_bits = comptime (2 * @bitSizeOf(T)) + levels.len;
    const Accumulator = std.meta.Int(.signed, acc_bits);

    var tmp: Accumulator = 0;
    for (inputs, weights) |input, weight|
        tmp += std.math.mulWide(T, input, weight);

    return @intCast(T, tmp >> (acc_bits - @bitSizeOf(T)));
}

pub fn AdsrEnvelopeGenerator(comptime T: type) type {
    assert(std.meta.trait.isSignedInt(T));
    return struct {
        profile: Profile,
        button: ?struct {
            timestamp: time.Absolute,
            state: ButtonState,
        },

        const Self = @This();
        const Envelope = std.meta.Int(.unsigned, @bitSizeOf(T) - 1);
        pub const Profile = struct {
            attack: time.Duration,
            decay: time.Duration,
            sustain: Envelope,
            release: time.Duration,
        };

        pub fn init(profile: Profile) Self {
            return Self{
                .profile = profile,
                .button = null,
            };
        }

        // x0 is assummed to be 0
        fn interpolate(
            x: time.Duration,
            x1: time.Duration,
            y0: T,
            y1: T,
        ) T {
            const y_span = y1 - y0;
            const x_delta = @intCast(i32, x.to_us());
            const x_span = @intCast(i32, x1.to_us());
            const y = y0 + @divFloor(std.math.mulWide(i32, x_delta, y_span), x_span);
            return @intCast(T, y);
        }

        pub fn apply_envelope(self: *Self, raw_sample: T) T {
            return if (self.button) |button| sample: {
                const attack = self.profile.attack;
                const decay = self.profile.decay;
                const sustain = self.profile.sustain;
                const release = self.profile.release;

                const now = time.get_time_since_boot();
                const delta = now.diff(button.timestamp);
                const envelope = switch (button.state) {
                    .pressed => if (delta.less_than(attack))
                        interpolate(delta, attack, 0, std.math.maxInt(Envelope))
                    else if (delta.less_than(attack.plus(decay)))
                        interpolate(delta.minus(attack), decay, std.math.maxInt(Envelope), sustain)
                    else
                        self.profile.sustain,

                    .released => if (delta.less_than(release))
                        interpolate(delta, release, sustain, 0)
                    else blk: {
                        self.button = null;
                        break :blk 0;
                    },
                };

                break :sample @intCast(T, std.math.mulWide(T, raw_sample, envelope) >> @bitSizeOf(Envelope));
            } else 0;
        }
    };
}
