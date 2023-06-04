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
const Keypad = workshop.Keypad;
const AdsrEnvelopeGenerator = workshop.AdsrEnvelopeGenerator(Sample);
const mix = workshop.mix;

// configuration
const sample_rate = 96_000;
const Sample = i16;

const pot = adc.input(2);
const I2S = workshop.I2S(Sample, .{ .sample_rate = sample_rate });

const sound_profile = notes.sound_profile_from_example(&.{
    .{ .freq = 440.0, .mag = 1.0 },
    .{ .freq = 880.0, .mag = 0.5 },
    .{ .freq = 2.0 * 880.0, .mag = 0.25 },
    .{ .freq = 4.0 * 880.0, .mag = 0.125 },
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
            col.* = workshop.phase_delta_from_float(sample_rate, overtone_freq);
        }
    }

    result[12] = [_]u32{0} ** sound_profile.len();
    for (result[13..], scale_freqs[14 .. 14 + 3]) |*row, fundamental_freq| {
        for (row, sound_profile.freqs) |*col, relative_freq| {
            const overtone_freq = fundamental_freq * relative_freq;
            col.* = workshop.phase_delta_from_float(sample_rate, overtone_freq);
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

    var vco_bank = [_]Oscillator{Oscillator.init(0)} ** sound_profile.len();
    var volume: u12 = 0;
    var keypad = Keypad.init(.{
        .row_pins = .{ 20, 21, 22, 26 },
        .col_pins = .{ 16, 17, 18, 19 },
        .period = time.Duration.from_us(2000),
    });
    var adsr = AdsrEnvelopeGenerator.init(.{
        .attack = time.Duration.from_ms(100),
        .decay = time.Duration.from_ms(100),
        .sustain = 0x1fff,
        .release = time.Duration.from_ms(1000),
    });

    while (true) {
        if (!i2s.is_writable())
            continue;

        keypad.tick();
        if (keypad.get_event()) |event| {
            adsr.feed_event(event);
            for (&vco_bank, 0..) |*vco, i|
                vco.delta = frequency_table[@enumToInt(event.button)][i];
        }

        // TODO: mix_wide
        for (&vco_bank) |*vco| vco.tick();
        const vco_output = mix(Sample, &sound_profile.levels, .{
            vco_bank[0].to_sine(Sample),
            vco_bank[1].to_sine(Sample),
            vco_bank[2].to_sine(Sample),
            vco_bank[3].to_sine(Sample),
        });

        adsr.tick();
        const sample = adsr.apply_envelope(vco_output);

        volume = adc.read_result() catch volume;
        i2s.write_mono(apply_volume(sample, volume));
    }
}
