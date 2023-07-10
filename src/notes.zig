//! This module contains functions and definitions for note frequencies
//! and their generation
//!
//! It uses the A4 = 440Hz tuning standard
const std = @import("std");
const assert = std.debug.assert;

const ref_index = calc_note_index(.A, Octave.num(4));
const a4_hz = 440.0;

pub const num_notes_in_octave = @typeInfo(Note).Enum.fields.len;

// Only 8 octaves supported -- that's good enough you cretins
pub const Octave = enum(u3) {
    _,

    pub fn num(n: u3) Octave {
        return @as(Octave, @enumFromInt(n));
    }
};

pub const Note = enum(u4) {
    A,
    @"A#/Bb",
    B,
    C,
    @"C#/Db",
    D,
    @"D#/Eb",
    E,
    F,
    @"F#/Gb",
    G,
    @"G#/Ab",
};

pub fn calc_frequency(note: Note, octave: Octave) f32 {
    const index = calc_note_index(note, octave);
    return frequency_from_index(note, index);
}

fn calc_note_index(note: Note, octave: Octave) i32 {
    return @intFromEnum(note) + (@as(i32, @intCast(num_notes_in_octave)) * @intFromEnum(octave));
}

fn frequency_from_index(index: i32) f32 {
    return a4_hz * std.math.pow(f32, 2, @as(f32, @floatFromInt(index - ref_index)) / @as(f32, @floatFromInt(num_notes_in_octave)));
}

/// calculate an octave's worth of a major scale starting from the "base" note
pub fn calc_major_scale(base_note: Note, octave: Octave) [7]f32 {
    const base_index = calc_note_index(base_note, octave);
    return .{
        frequency_from_index(base_index),
        frequency_from_index(base_index + 2), // whole
        frequency_from_index(base_index + 4), // whole
        frequency_from_index(base_index + 5), // half
        frequency_from_index(base_index + 7), // whole
        frequency_from_index(base_index + 9), // whole
        frequency_from_index(base_index + 11), // whole
    };
}

pub fn calc_minor_scale(base_note: Note, octave: Octave) [7]f32 {
    const base_index = calc_note_index(base_note, octave);
    return .{
        frequency_from_index(base_index),
        frequency_from_index(base_index + 2), // whole
        frequency_from_index(base_index + 3), // half
        frequency_from_index(base_index + 5), // whole
        frequency_from_index(base_index + 7), // whole
        frequency_from_index(base_index + 8), // half
        frequency_from_index(base_index + 10), // whole
    };
}

pub fn calc_full_octave(octave: Octave) [12]f32 {
    const base_index = calc_note_index(.A, octave);
    var result: [12]f32 = undefined;
    for (&result, 0..) |*r, i|
        r.* = frequency_from_index(base_index + @as(i32, @intCast(i)));

    return result;
}

pub fn SoundProfile(comptime size: usize) type {
    return struct {
        levels: [size]f64,
        freqs: [size]f64,

        pub fn len(self: @This()) usize {
            _ = self;
            return size;
        }
    };
}

/// converts decibel units to magnitude
pub fn db(decibel: f64) f64 {
    return 20.0 * std.math.pow(f64, 10.0, decibel);
}

pub fn sound_profile_from_example(comptime example: []const struct {
    freq: f64,
    mag: f64,
}) SoundProfile(example.len) {
    var result: SoundProfile(example.len) = undefined;

    const mag_sum = mag_sum: {
        var sum: f64 = 0;
        for (example) |e|
            sum += e.mag;

        break :mag_sum sum;
    };

    var level_sum: f64 = 0.0;
    for (&result.levels, &result.freqs, example) |*l, *f, e| {
        l.* = e.mag / mag_sum;
        // frequency  ration wrt fundamental
        f.* = e.freq / example[0].freq;

        level_sum += l.*;
    }

    const epsilon = std.math.floatEps(f64);
    assert(level_sum < (1.0 + epsilon) and
        level_sum > (1.0 - epsilon));

    return result;
}
