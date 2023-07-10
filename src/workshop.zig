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
    return @as(Sample, @intCast(product >> 12));
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

pub fn phase_delta_from_float(sample_rate: u32, frequency: f64) u32 {
    return @as(
        u32,
        @intFromFloat(frequency / @as(f64, @floatFromInt(sample_rate)) * std.math.pow(f64, 2, 32)),
    );
}

pub const FrequencyRatio = packed struct(u16) {
    int: u8,
    frac: u8 = 0,
};

/// The oscillator takes advantage of integer overflow to represent radians as
/// you rotate about a circle. It assumes 32-bit architecture so that maximum
/// precision is achieved with minimum runtime cost.
///
/// The sample rate is known at compile time, and the frequency can be changed
/// at runtime.
/// TODO: remove comptime param
pub fn Oscillator(comptime sample_rate: u32) type {
    return struct {
        phase: u32 = 0,
        delta: u32 = 0,

        const Self = @This();

        pub fn init(frequency: u32) Self {
            return Self{
                .phase = 0,
                .delta = calculate_delta(frequency),
            };
        }

        pub fn reset(self: *Self) void {
            self.phase = 0;
            self.delta = 0;
        }

        fn calculate_delta(frequency: u32) u32 {
            return @as(u32, @intCast((@as(u64, 0x100000000) * frequency) / sample_rate));
        }

        pub fn tick(self: *Self) void {
            self.phase +%= self.delta;
        }

        pub fn tick_modulate(self: *Self, comptime T: type, input: T, ratio: FrequencyRatio) void {
            comptime assert(std.meta.trait.isSignedInt(T));
            // TODO: calculate Accumulator
            const base = @as(i64, @intCast(self.delta)) * input;
            const mod_delta = ((base * ratio.int) >> @bitSizeOf(T)) +
                ((base * ratio.frac) >> (@bitSizeOf(T) + 8));
            // TODO: will have truncated bits I think
            if (mod_delta < 0)
                self.phase -%= @as(u32, @intCast(-mod_delta))
            else
                self.phase +%= @as(u32, @intCast(mod_delta));
        }

        pub fn set_frequency(self: *Self, frequency: u32) void {
            self.delta = calculate_delta(frequency);
        }

        /// at compile time,
        pub fn set_frequency_float(self: *Self, comptime frequency: f32) void {
            self.delta = comptime phase_delta_from_float(sample_rate, frequency);
        }

        pub fn to_sawtooth(self: Self, comptime T: type) T {
            comptime assert(std.meta.trait.isSignedInt(T));

            const UnsignedSample = std.meta.Int(.unsigned, @bitSizeOf(T));
            return @as(T, @bitCast(@as(
                UnsignedSample,
                @truncate(self.phase >> 32 - @bitSizeOf(T)),
            )));
        }

        pub fn to_square(self: Self, comptime T: type) T {
            comptime assert(std.meta.trait.isSignedInt(T));

            return if (self.delta != 0)
                if (self.phase > (std.math.maxInt(u32) / 2))
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
                const radian_delta = (2.0 * std.math.pi) / @as(comptime_float, @floatFromInt(samples));

                for (0..samples) |i|
                    ret[i] = @as(T, @intFromFloat(@as(f64, @floatFromInt(std.math.maxInt(T))) * @sin(@as(f64, @floatFromInt(i)) * radian_delta)));

                break :blk ret;
            };

            const lut_bits = comptime std.math.log2(lut.len);
            const LutIndex = std.meta.Int(.unsigned, lut_bits);
            const x_span = comptime 1 << (32 - lut_bits);

            const y0_index: LutIndex = @as(LutIndex, @intCast(self.phase >> @as(u5, 32 - lut_bits)));
            const y1_index = y0_index +% 1;

            const y0 = lut[y0_index];
            const y1 = lut[y1_index];

            const x0 = @as(u32, y0_index) * x_span;

            const y_span = y1 - y0;

            const x_delta = @as(i32, @intCast(self.phase - x0));
            // TODO: fix overflow here
            const y = y0 + @divFloor(std.math.mulWide(i32, x_delta, y_span), x_span);

            return @as(T, @intCast(y));
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
        return @as(Button, @enumFromInt(@as(u4, @bitCast(coord))));
    }
};

pub const Keypad = struct {
    order: OrderList,
    pressed: [16]bool,
    timestamps: [16]time.Absolute,
    last_released: ?Button,
    deadline: time.Absolute,
    row: u2,
    state_changed: bool,
    row_pins: [4]u5,
    col_pins: [4]u5,
    period: time.Duration,
    col_mask: gpio.Mask,
    row_mask: gpio.Mask,

    const Self = @This();

    const OrderList = std.BoundedArray(Button, 16);

    pub const Options = struct {
        row_pins: [4]u5,
        col_pins: [4]u5,
        period: time.Duration,
    };

    pub const ButtonState = enum(u1) {
        pressed,
        released,
    };

    pub const Event = struct {
        timestamp: time.Absolute,
        kind: ButtonState,
        button: Button,
    };

    pub fn init(comptime options: Options) Self {
        const row_mask = comptime blk: {
            var result: u32 = 0;
            inline for (options.row_pins) |pin|
                result |= @as(u32, 1) << pin;

            break :blk gpio.mask(result);
        };

        const col_mask = comptime blk: {
            var result: u32 = 0;
            inline for (options.col_pins) |pin|
                result |= @as(u32, 1) << pin;

            break :blk gpio.mask(result);
        };

        comptime assert(0 == (@intFromEnum(row_mask) & @intFromEnum(col_mask))); // pins overlap

        col_mask.set_function(.sio);
        col_mask.set_direction(.in);
        col_mask.set_pull(.down);

        // we scan by rows, so they are the outputs
        row_mask.set_function(.sio);
        row_mask.set_direction(.out);

        return Self{
            .order = OrderList.init(0) catch unreachable,
            .pressed = [_]bool{false} ** 16,
            .timestamps = [_]time.Absolute{@as(time.Absolute, @enumFromInt(0))} ** 16,
            .last_released = null,
            // TODO: figure out if this is okay
            .deadline = time.make_timeout_us(0),
            .row = 0,
            .state_changed = false,
            .period = options.period,
            .col_pins = options.col_pins,
            .row_pins = options.row_pins,
            .col_mask = col_mask,
            .row_mask = row_mask,
        };
    }

    pub fn tick(self: *Self) void {
        if (!self.deadline.is_reached())
            return;

        const result = self.col_mask.read();
        for (self.col_pins, 0..) |pin, col| {
            const button = Button.from_coord(.{
                .row = self.row,
                .col = @as(u2, @intCast(col)),
            });

            // detect that state has changed
            const prev = self.pressed[@intFromEnum(button)];
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
                self.pressed[@intFromEnum(button)] = true;
            } else { // released
                const index = std.mem.indexOfScalar(Button, self.order.slice(), button).?;
                _ = self.order.orderedRemove(index);
                self.last_released = button;
                self.pressed[@intFromEnum(button)] = false;
            }

            // update timestamp to last state update
            self.timestamps[@intFromEnum(button)] = time.get_time_since_boot();
            self.state_changed = true;
        }

        self.row +%= 1;
        self.row_mask.put(@as(u32, 1) << self.row_pins[self.row]);
        self.deadline = time.make_timeout_us(self.period.to_us() / 4);
    }

    pub fn get_event(self: *Self) ?Event {
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

            break :event Event{
                .kind = kind,
                .button = button,
                .timestamp = self.timestamps[@intFromEnum(button)],
            };
        } else null;
    }
};

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
        for (float_weights, 0..) |float, i| {
            fixed_weights[i] = @as(T, @intFromFloat(std.math.round(@as(f64, @floatFromInt(std.math.maxInt(T))) * float)));
            assert(fixed_weights[i] != 0); // float weight was so small it doesn't fit
        }

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

    return @as(T, @intCast(tmp >> (acc_bits - (@bitSizeOf(T) + levels.len))));
}

pub fn AdsrEnvelopeGenerator(comptime T: type) type {
    assert(std.meta.trait.isSignedInt(T));
    return struct {
        profile: Profile,
        envelope: Envelope,
        state: State,

        const Self = @This();
        const Envelope = std.meta.Int(.unsigned, @bitSizeOf(T) - 1);
        const envelope_max = std.math.maxInt(Envelope);
        const Interval = struct {
            from: time.Absolute,
            to: time.Absolute,
        };
        const State = union(enum) {
            attack: struct {
                start: time.Absolute,
                attack_end: time.Absolute,
                decay_end: time.Absolute,
            },
            decay: struct {
                start: time.Absolute,
                end: time.Absolute,
            },
            sustain: void,
            release: struct {
                start: struct {
                    time: time.Absolute,
                    value: Envelope,
                },
                end: time.Absolute,
            },
            off: void,
        };

        pub const Profile = struct {
            attack: time.Duration,
            decay: time.Duration,
            sustain: Envelope,
            release: time.Duration,
        };

        pub fn init(profile: Profile) Self {
            // TODO: remove
            return Self{
                .profile = profile,
                .state = .{ .off = {} },
                .envelope = 0,
            };
        }

        /// Move machinery forward, this will transition state if it's time:
        ///
        /// - attack -> decay
        /// - decay -> sustain
        /// - release -> off
        ///
        /// It then calculates the envelope magnitude given the current state.
        pub fn tick(self: *Self) void {

            //==================================
            // Update state
            //==================================

            const now = time.get_time_since_boot();
            switch (self.state) {
                .attack => |state| if (state.decay_end.is_reached_by(now)) {
                    self.state = .{ .sustain = {} };
                } else if (state.attack_end.is_reached_by(now)) {
                    self.state = .{
                        .decay = .{
                            .start = state.attack_end,
                            .end = state.attack_end.add_duration(self.profile.decay),
                        },
                    };
                },
                .decay => |state| if (state.end.is_reached_by(now)) {
                    self.state = .{ .sustain = {} };
                },
                .release => |state| if (state.end.is_reached_by(now)) {
                    self.state = .{ .off = {} };
                },
                .off, .sustain => {},
            }

            //==================================
            // Envelope calculations
            //==================================

            self.envelope = switch (self.state) {
                .attack => |state| envelope: {
                    assert(!state.attack_end.is_reached_by(now));
                    const delta = now.diff(state.start);
                    break :envelope interpolate(
                        delta,
                        self.profile.attack,
                        0,
                        envelope_max,
                    );
                },
                .decay => |state| envelope: {
                    assert(!state.end.is_reached_by(now));
                    const delta = now.diff(state.start);
                    break :envelope interpolate(
                        delta,
                        self.profile.decay,
                        envelope_max,
                        self.profile.sustain,
                    );
                },
                .sustain => self.profile.sustain,
                // the last value of the envelope is used to interpolate
                // because the key may have been released before transitioning
                // to decay. If we don't take this into consideration, the
                // envelop shoots up to max value when you release a key early.
                .release => |state| envelope: {
                    assert(!state.end.is_reached_by(now));
                    const delta = now.diff(state.start.time);
                    break :envelope interpolate(
                        delta,
                        self.profile.release,
                        state.start.value,
                        0,
                    );
                },
                .off => 0,
            };
        }

        /// A new sudden event has taken place and the state machine must be
        /// updated accordingly.
        pub fn feed_event(self: *Self, event: Keypad.Event) void {
            const profile = self.profile;
            const timestamp = event.timestamp;
            self.state = switch (event.kind) {
                .pressed => blk: {
                    const attack_end = timestamp.add_duration(profile.attack);
                    break :blk .{
                        .attack = .{
                            .start = event.timestamp,
                            .attack_end = attack_end,
                            .decay_end = attack_end.add_duration(profile.decay),
                        },
                    };
                },
                .released => .{
                    .release = .{
                        .start = .{
                            .time = timestamp,
                            .value = self.envelope,
                        },
                        .end = event.timestamp.add_duration(profile.release),
                    },
                },
            };
        }

        pub fn apply_envelope(self: Self, raw_sample: T) T {
            const wide = std.math.mulWide(T, raw_sample, self.envelope);
            const shifted = wide >> @bitSizeOf(Envelope);
            return @as(T, @intCast(shifted));
        }

        // x0 is assummed to be 0
        fn interpolate(
            x: time.Duration,
            x1: time.Duration,
            y0: T,
            y1: T,
        ) Envelope {
            const y_span = y1 - y0;
            const x_delta = @as(i32, @intCast(x.to_us()));
            const x_span = @as(i32, @intCast(x1.to_us()));
            assert(x_span >= x_delta);
            const y = y0 + @divFloor(std.math.mulWide(i32, x_delta, y_span), x_span);
            return @as(Envelope, @intCast(y));
        }

        comptime {
            @setEvalBranchQuota(10000);
            const profile = Profile{
                .attack = time.Duration.from_us(100),
                .decay = time.Duration.from_us(200),
                .sustain = 0x1fff,
                .release = time.Duration.from_us(300),
            };

            var last: Envelope = 0;
            for (0..profile.attack.to_us() + 1) |t| {
                const envelope = interpolate(
                    time.Duration.from_us(t),
                    profile.attack,
                    0,
                    envelope_max,
                );

                assert(envelope >= 0);
                assert(envelope <= envelope_max);
                assert(last <= envelope);
                last = envelope;
            }

            last = envelope_max;
            for (0..profile.decay.to_us() + 1) |t| {
                const envelope = interpolate(
                    time.Duration.from_us(t),
                    profile.decay,
                    envelope_max,
                    profile.sustain,
                );

                assert(envelope <= envelope_max);
                assert(envelope >= profile.sustain);
                assert(envelope <= last);
                last = envelope;
            }
        }
    };
}

pub fn Operator(comptime Sample: type, comptime sample_rate: u32) type {
    return struct {
        vco: Oscillator(sample_rate),
        adsr: AdsrEnvelopeGenerator(Sample),
        feedback: u8,
        input: Sample,
        freq_ratio: FrequencyRatio,

        const Self = @This();

        pub const Event = struct {
            keypad: Keypad.Event,
            vco_delta: u32,
        };

        pub fn init(args: struct {
            profile: AdsrEnvelopeGenerator(Sample).Profile,
            freq_ratio: FrequencyRatio = .{ .int = 0, .frac = 0 },
        }) Self {
            return Self{
                .vco = Oscillator(sample_rate).init(0),
                .adsr = AdsrEnvelopeGenerator(Sample).init(args.profile),
                .feedback = 0,
                .input = 0,
                .freq_ratio = args.freq_ratio,
            };
        }

        pub fn tick(self: *Self) void {
            self.vco.tick_modulate(Sample, self.input, self.freq_ratio);
            self.vco.tick();
            self.adsr.tick();
        }

        pub fn to_sine(self: Self) Sample {
            return self.adsr.apply_envelope(self.vco.to_sine(Sample));
        }

        pub fn to_sawtooth(self: Self) Sample {
            return self.adsr.apply_envelope(self.vco.to_sawtooth(Sample));
        }

        pub fn to_square(self: Self) Sample {
            return self.adsr.apply_envelope(self.vco.to_square(Sample));
        }

        pub fn feed_event(self: *Self, event: Event) void {
            self.adsr.feed_event(event.keypad);
            self.vco.delta = event.vco_delta;
        }
    };
}
