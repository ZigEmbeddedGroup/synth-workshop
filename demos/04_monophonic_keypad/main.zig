const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const cpu = microzig.cpu;
const rp2040 = microzig.hal;
const gpio = rp2040.gpio;
const irq = rp2040.irq;
const adc = rp2040.adc;
const time = rp2040.time;

// code for this workshop
const workshop = @import("workshop");
const Oscillator = workshop.Oscillator;
const apply_volume = workshop.apply_volume;
const notes = workshop.notes;
const Keypad = workshop.Keypad;

// configuration
const sample_rate = 44_100;
const Sample = i16;

const pot = adc.input(2);
const I2S = workshop.I2S(Sample, .{ .sample_rate = sample_rate });

const frequency_table: [16]u32 = blk: {
    const scale_freqs =
        notes.calc_major_scale(.C, notes.Octave.num(3)) ++
        notes.calc_major_scale(.C, notes.Octave.num(4)) ++
        notes.calc_major_scale(.C, notes.Octave.num(5));

    var result: [16]u32 = undefined;
    for (&result, scale_freqs[0..result.len]) |*r, freq|
        r.* = workshop.phase_delta_from_float(sample_rate, freq);

    break :blk result;
};

pub fn main() !void {
    const i2s = I2S.init(.pio0, .{
        .clock_config = rp2040.clock_config,
        .clk_pin = gpio.num(2),
        .word_select_pin = gpio.num(3),
        .data_pin = gpio.num(4),
    });

    pot.configure_gpio_pin();
    adc.apply(.{ .sample_frequency = 1000 });
    adc.select_input(pot);
    adc.start(.free_running);

    var vco = Oscillator(sample_rate).init(0);
    var volume: u12 = 0;
    var keypad = Keypad.init(.{
        .row_pins = .{ 20, 21, 22, 26 },
        .col_pins = .{ 16, 17, 18, 19 },
        .period = time.Duration.from_us(2000),
    });

    while (true) {
        if (!i2s.is_writable())
            continue;

        keypad.tick();
        if (keypad.get_event()) |event| switch (event.kind) {
            .pressed => vco.delta = frequency_table[@enumToInt(event.button)],
            .released => vco.reset(),
        };

        vco.tick();
        const sample = vco.to_sine(Sample);

        volume = adc.read_result() catch volume;
        i2s.write_mono(apply_volume(sample, volume));
    }
}
