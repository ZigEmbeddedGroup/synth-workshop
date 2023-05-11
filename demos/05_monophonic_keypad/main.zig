const std = @import("std");
const microzig = @import("microzig");
const cpu = microzig.cpu;
const rp2040 = microzig.hal;
const gpio = rp2040.gpio;
const irq = rp2040.irq;

// code for this workshop
const workshop = @import("workshop");
const Oscillator = workshop.Oscillator;

// configuration
const sample_rate = 96_000;
const Sample = i16;

const I2S = workshop.I2S(Sample, .{ .sample_rate = sample_rate });
const Keypad = workshop.Keypad(.{
    .row_pins = .{ 20, 21, 22, 26 },
    .col_pins = .{ 16, 17, 18, 19 },
    .period_us = 2000,
});

const frequency_table: [16]u32 = blk: {
    //const scale_freqs = workshop.notes.calc_full_octave(workshop.notes.Octave.num(4));
    // TODO: I screwed up note calcs
    const scale_freqs =
        workshop.notes.calc_major_scale(.C, workshop.notes.Octave.num(3)) ++
        workshop.notes.calc_major_scale(.C, workshop.notes.Octave.num(4));

    var result: [16]u32 = undefined;
    inline for (scale_freqs, 0..) |float, i|
        result[i] = workshop.update_count_from_float(sample_rate, float);

    for (scale_freqs.len..result.len) |i|
        result[i] = 0;

    break :blk result;
};

pub fn main() !void {
    const i2s = I2S.init(.pio0, .{
        .clock_config = rp2040.clock_config,
        .clk_pin = gpio.num(2),
        .word_select_pin = gpio.num(3),
        .data_pin = gpio.num(4),
    });

    var keypad = Keypad.init();
    var osc = Oscillator(sample_rate).init(0);

    while (true) {
        if (i2s.is_writable()) {
            osc.tick();

            keypad.tick();
            const sample: i16 = if (keypad.get_pressed()) |button| blk: {
                osc.update_count = frequency_table[@enumToInt(button)];
                break :blk if (osc.update_count != 0)
                    osc.to_sawtooth(Sample)
                else
                    0;
            } else 0;

            i2s.write_mono(sample);
        }
    }
}
