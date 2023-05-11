//! This module contains functions and definitions for note frequencies
//! and their generation
//!
//! It uses the A4 = 440Hz tuning standard
const std = @import("std");

const ref_index = calc_note_index(.A, Octave.num(4));
const a4_hz = 440.0;

pub const num_notes_in_octave = @typeInfo(Note).Enum.fields.len;

// Only 8 octaves supported -- that's good enough you cretins
pub const Octave = enum(u3) {
    _,

    pub fn num(n: u3) Octave {
        return @intToEnum(Octave, n);
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
    return @enumToInt(note) + (@intCast(i32, num_notes_in_octave) * @enumToInt(octave));
}

fn frequency_from_index(index: i32) f32 {
    return a4_hz * std.math.pow(f32, 2, @intToFloat(f32, index - ref_index) / @intToFloat(f32, num_notes_in_octave));
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
        r.* = frequency_from_index(base_index + @intCast(i32, i));

    return result;
}
