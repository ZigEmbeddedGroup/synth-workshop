//! This module provides a view of your synth on the RP2040 by sending data
//! over the UART. It has global fields because it assumes exclusive use of the
//! second core for an FFT transform
//!
//! Assuming a baud rate of 115200, it aims to fill half that bandwidth with
//! FFT frames for visualization on your PC.
const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const rp2040 = microzig.hal;
const gpio = rp2040.gpio;
const clocks = rp2040.clocks;
const time = rp2040.time;
const irq = rp2040.irq;
const dma = rp2040.dma;
const fifo = rp2040.multicore.fifo;

const workshop = @import("workshop.zig");
const Volatile = workshop.Volatile;

const log_length_max = 80;
const buffered_logs_max = 16;
const fft_samples = 32;
const stack_trace_depth_max = 16;

const uart = rp2040.uart.num(0);
const channel = dma.num(0);

var fft_result = FftBuffer.init();
var logs = LogsBuffer.init();
var dma_running = Volatile(bool).init(false);

pub const Message = extern struct {
    kind: Kind,

    pub const Kind = enum(u8) {
        log,
        fft,
    };

    pub const LogHeader = packed struct {
        level: std.log.Level,
        len: u16,
    };

    pub const FftHeader = packed struct {
        sample_rate: u24,
        len: u16,
    };
};

pub const interrupts = struct {
    /// This handler runs when the transfer is complete.
    pub fn DMA_IRQ_0() void {
        channel.acknowledge_irq0();
        assert(!channel.is_busy());

        // we're done with the front of the queue
        logs.pop_buffer();

        // TODO: pick highest priority message
        if (!logs.empty())
            trigger_dma()
        else
            dma_running.store(false);
    }

    /// this handler waits for incoming samples from the other processor
    /// and enqueues them
    pub fn SIO_IRQ_PROC0() void {
        // TODO do we need to acknowledge this interrupt?
        while (fifo.read()) |value|
            fft_result.append(value);

        if (fft_result.full() and !channel.is_busy())
            trigger_dma();
    }
};

/// initializes the UART
pub fn init() void {
    // TODO: uart init
    //irq.enable("SIO_IRQ_0");
    //uart.claim();
    channel.claim();

    uart.apply(.{
        .baud_rate = 115200,
        .tx_pin = gpio.num(0), // Use GP0 for TX
        .rx_pin = gpio.num(1), // Use GP1 for RX
        .clock_config = rp2040.clock_config,
    });

    channel.set_irq0_enabled(true);
    irq.enable("DMA_IRQ_0");

    std.log.info("================ STARTING MONITOR SESSION ================", .{});

    // TODO: launch core1 with fft task
}

pub fn trigger_dma() void {
    assert(!channel.is_busy());

    const front = logs.get_front();
    channel.trigger_transfer(
        @ptrToInt(uart.tx_fifo()),
        @ptrToInt(&front.buffer),
        front.len,
        .{
            .transfer_size_bytes = 1,
            .dreq = uart.dreq_tx(),
            .enable = true,
            .read_increment = true,
            .write_increment = false,
        },
    );

    dma_running.store(true);
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_prefix = comptime "[{}.{:0>6}] " ++ level.asText();
    const prefix = comptime level_prefix ++ switch (scope) {
        .default => ": ",
        else => " (" ++ @tagName(scope) ++ "): ",
    };

    // need these off to check on the DMA channel and ensure we don't
    // have a race condition
    microzig.cpu.disable_interrupts();
    defer microzig.cpu.enable_interrupts();

    // If there's no more space then we drop the log
    // TODO: log for how many logs were missed
    if (logs.acquire_buffer()) |volatile_buffer| {
        const current_time = time.get_time_since_boot();
        const seconds = current_time.us_since_boot / std.time.us_per_s;
        const microseconds = current_time.us_since_boot % std.time.us_per_s;

        const buffer = @volatileCast(volatile_buffer);
        // if we fail to print a log then something is fishy
        buffer.writer().print(prefix ++ format ++ "\r\n", .{ seconds, microseconds } ++ args) catch {
            @panic("failed to print a log, maybe it overwrote the buffer?");
        };

        // if the channel is busy then we can rely on the interrupt
        // handler to continue processing logs. But if it stopped then we
        // need to trigger another transfer
        if (!dma_running.load_with_disabled_irqs())
            trigger_dma();
    }
}

const FftBuffer = struct {
    buf: [2 + fft_samples]u32,
    len: u32,

    const Self = @This();
    pub fn init() Self {
        return Self{
            .buf = undefined,
            .len = 0,
        };
    }

    pub fn append(self: *volatile Self, sample: u32) void {
        if (self.full())
            @panic("FFT buffer overflow");

        self.buf[self.len] = sample;
        self.len += 1;
    }

    pub fn full(self: *volatile Self) bool {
        return self.len == self.buf.len;
    }

    pub fn reset(self: *volatile Self) void {
        // TODO: fill in kind, length, and sample rate
        self.len = 0;
    }
};

const LogsBuffer = struct {
    items: [buffered_logs_max]LogBuffer,
    start: u32,
    len: u32,

    const LogBuffer = std.BoundedArray(u8, 3 + log_length_max);
    const Self = @This();

    pub fn init() Self {
        return Self{
            .items = undefined,
            .start = 0,
            .len = 0,
        };
    }

    pub fn empty(self: *const volatile Self) bool {
        return self.len == 0;
    }

    pub fn get_front(self: *const volatile Self) *const volatile LogBuffer {
        assert(!self.empty());

        return &self.items[self.start];
    }

    pub fn acquire_buffer(self: *volatile Self) ?*volatile LogBuffer {
        if (self.len >= buffered_logs_max)
            return null;

        const index = (self.start + self.len) % buffered_logs_max;
        self.len += 1;

        const ret = &self.items[index];
        ret.len = 0;
        return ret;
    }

    pub fn pop_buffer(self: *volatile Self) void {
        self.len -= 1;
        self.start += 1;
        self.start %= buffered_logs_max;
    }
};
