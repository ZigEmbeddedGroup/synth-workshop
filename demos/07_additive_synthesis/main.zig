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
const Oscillator = workshop.Oscillator(sample_rate);
const apply_volume = workshop.apply_volume;
const notes = workshop.notes;
const AdsrEnvelopeGenerator = workshop.AdsrEnvelopeGenerator(Sample);
const mix = workshop.mix;

// configuration
const sample_rate = 96_000;
const Sample = i16;

const pot = adc.input(2);
const I2S = workshop.I2S(Sample, .{ .sample_rate = sample_rate });
const Keypad = workshop.Keypad(.{
    .row_pins = .{ 20, 21, 22, 26 },
    .col_pins = .{ 16, 17, 18, 19 },
    .period_us = 2000,
});

const sound_profile = notes.sound_profile_from_example(&.{
    .{ .freq = 440.0, .mag = 1.0 },
    //.{ .freq = 880.0, .mag = 1.0 },
    //.{ .freq = 701.0, .mag = notes.db(-21.6) },
    //.{ .freq = 925.0, .mag = notes.db(-67.3) },
    //.{ .freq = 2092.0, .mag = notes.db(-46.0) },
    //.{ .freq = 2788.0, .mag = notes.db(-66.7) },
});

const frequency_table: [16][sound_profile.len()]u32 = blk: {
    const scale_freqs =
        notes.calc_major_scale(.@"A#/Bb", notes.Octave.num(2)) ++
        notes.calc_major_scale(.@"A#/Bb", notes.Octave.num(3)) ++
        notes.calc_major_scale(.@"A#/Bb", notes.Octave.num(4));

    var result: [16][sound_profile.len()]u32 = undefined;
    for (result[0..12], scale_freqs[2..14]) |*row, fundamental_freq| {
        for (row, sound_profile.freqs) |*col, relative_freq| {
            const overtone_freq = fundamental_freq * relative_freq;
            col.* = workshop.update_count_from_float(sample_rate, overtone_freq);
        }
    }

    result[12] = [_]u32{0} ** sound_profile.len();
    for (result[13..], scale_freqs[14 .. 14 + 3]) |*row, fundamental_freq| {
        for (row, sound_profile.freqs) |*col, relative_freq| {
            const overtone_freq = fundamental_freq * relative_freq;
            col.* = workshop.update_count_from_float(sample_rate, overtone_freq);
        }
    }

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

    var keypad = Keypad.init();
    var volume: u12 = 0;
    var osc_bank = [_]Oscillator{Oscillator.init(0)} ** sound_profile.len();

    var adsr = AdsrEnvelopeGenerator.init(.{
        .attack = time.Duration.from_ms(0),
        .decay = time.Duration.from_ms(0),
        .sustain = 0x7fff,
        .release = time.Duration.from_ms(10),
    });

    while (true) {
        if (i2s.is_writable()) {
            volume = adc.read_result() catch volume;

            keypad.tick();
            if (keypad.get_event()) |event| {
                for (&osc_bank, 0..) |*osc, i|
                    osc.update_count = frequency_table[@enumToInt(event.button)][i];

                adsr.button = .{
                    .timestamp = event.timestamp,
                    .state = event.kind,
                };
            }

            for (&osc_bank) |*osc|
                osc.tick();

            const osc_output = mix(Sample, &sound_profile.levels, .{
                osc_bank[0].to_sine(Sample),
                //osc_bank[1].to_sine(Sample),
            });
            const sample = adsr.apply_envelope(osc_output);

            i2s.write_mono(apply_volume(sample, volume));
        }
    }
}
