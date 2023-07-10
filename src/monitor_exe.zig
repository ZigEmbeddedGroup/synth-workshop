const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const rl = @import("raylib");

pub fn main() anyerror!void {
    const screen_width = 800;
    const screen_height = 450;
    const margin = 10;
    const panel_width = screen_width - (2 * margin);
    const panel_height = (screen_height - (3 * margin)) / 2;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var logger = Logger.init(gpa.allocator(), .{
        .x = margin,
        .y = panel_height + (2 * margin),
        .width = panel_width,
        .height = panel_height,
        .background = rl.DARKGRAY,
        .font_size = 12,
        .font_color = rl.GREEN,
        .margin = 5,
        .side_margin = margin,
    });
    defer logger.deinit();

    var fft = FFT.init(gpa.allocator(), .{
        .x = margin,
        .y = margin,
        .width = panel_width,
        .height = panel_height,
        .background = rl.LIGHTGRAY,
        .bar_color = rl.PURPLE,
        .axes_color = rl.DARKGRAY,
    });
    defer fft.deinit();

    // TODO: remove
    //var rng = std.rand.DefaultPrng.init(0);
    //fft.sample_rate = 96_000;
    //for (0..panel_width) |_|
    //    try fft.samples.append(rng.random().int(i16));

    rl.InitWindow(screen_width, screen_height, "Synthesizer Monitor");
    rl.SetTargetFPS(60);
    while (!rl.WindowShouldClose()) { // Detect window close button or ESC key
        // Update

        // TODO: read lines from serial port

        // Draw
        rl.BeginDrawing();
        rl.ClearBackground(rl.WHITE);
        fft.draw();
        logger.draw();
        rl.EndDrawing();
    }

    rl.CloseWindow();
}

const Logger = struct {
    allocator: Allocator,
    settings: Settings,
    logs: std.ArrayListUnmanaged([:0]const u8) = .{},

    const Settings = struct {
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        background: rl.Color,
        font_size: c_int,
        font_color: rl.Color,
        margin: c_int,
        side_margin: c_int,
    };

    fn init(allocator: Allocator, settings: Settings) Logger {
        return Logger{
            .allocator = allocator,
            .settings = settings,
        };
    }

    fn deinit(logger: *Logger) void {
        for (logger.logs.items) |log|
            logger.allocator.free(log);

        logger.logs.deinit(logger.allocator);
    }

    fn draw_background_panel(logger: Logger) void {
        const settings = logger.settings;

        // zig fmt: off
        const background = settings.background;
        const height     = settings.height;
        const width      = settings.width;
        const x          = settings.x;
        const y          = settings.y;
        // zig fmt: on

        rl.DrawRectangle(x, y, width, height, background);
    }

    fn draw_log_lines(logger: Logger) void {
        const settings = logger.settings;

        // zig fmt: off
        const font_color = settings.font_color;
        const font_size  = settings.font_size;
        const height     = settings.height;
        const margin     = settings.margin;
        const x          = settings.x;
        const y          = settings.y;
        // zig fmt: on

        const num_lines_max: usize = @as(usize, @intCast(@divFloor(height, (font_size + margin))));
        const num_lines: usize = if (logger.logs.items.len > num_lines_max)
            num_lines_max
        else
            logger.logs.items.len;

        for (logger.logs.items[logger.logs.items.len - num_lines .. logger.logs.items.len], 0..) |line, i| {
            const line_x = x + margin;
            const line_y = y + height - (@as(c_int, @intCast(num_lines - i)) * (margin + font_size));
            rl.DrawText(line.ptr, line_x, line_y, font_size, font_color);
        }
    }

    // cuts off lines that are too long, assumes the app's background is white
    fn draw_text_cutoff(logger: Logger) void {
        const settings = logger.settings;

        // zig fmt: off
        const height      = settings.height;
        const side_margin = settings.side_margin;
        const width       = settings.width;
        const x           = settings.x;
        const y           = settings.y;
        // zig fmt: on

        rl.DrawRectangle(x + width, y, side_margin, height, rl.WHITE);
    }

    fn draw(logger: Logger) void {
        logger.draw_background_panel();
        logger.draw_log_lines();
        logger.draw_text_cutoff();
    }

    fn append(logger: *Logger, line: []const u8) !void {
        const allocator = logger.allocator;
        const copy = try allocator.dupeZ(u8, line);
        errdefer allocator.free(copy);

        try logger.logs.append(allocator, copy);
    }
};

const FFT = struct {
    sample_rate: u32,
    samples: std.ArrayList(i16),
    settings: Settings,

    const Settings = struct {
        background: rl.Color,
        height: c_int,
        width: c_int,
        x: c_int,
        y: c_int,
        bar_color: rl.Color,
        axes_color: rl.Color,
    };

    fn init(allocator: Allocator, settings: Settings) FFT {
        return FFT{
            .sample_rate = undefined,
            .samples = std.ArrayList(i16).init(allocator),
            .settings = settings,
        };
    }

    fn draw_background(fft: FFT) void {
        const settings = fft.settings;

        // zig fmt: off
        const background = settings.background;
        const height     = settings.height;
        const width      = settings.width;
        const x          = settings.x;
        const y          = settings.y;
        // zig fmt: on

        rl.DrawRectangle(x, y, width, height, background);
    }

    fn draw_axes(fft: FFT) void {
        const settings = fft.settings;

        // zig fmt: off
        const spacing = 20;
        const panel_x = settings.x;
        const panel_y = settings.y;
        const panel_height = settings.height;
        const panel_width = settings.width;
        const axes_color = settings.axes_color;
        // zig fmt: on

        // y axis line
        rl.DrawLine(
            panel_x + spacing,
            panel_y + spacing,
            panel_x + spacing,
            panel_y + panel_height - spacing,
            axes_color,
        );

        // x axis line
        rl.DrawLine(
            panel_x + spacing,
            panel_y + panel_height - spacing,
            panel_x + panel_width - spacing,
            panel_y + panel_height - spacing,
            axes_color,
        );
    }

    fn draw_graph(fft: FFT) void {
        const settings = fft.settings;

        // zig fmt: off
        const panel_x      = settings.x;
        const panel_y      = settings.y;
        const panel_height = settings.height;
        const bar_color    = settings.bar_color;
        // zig fmt: on

        for (fft.samples.items, 0..) |raw_sample, x_offset| {
            const sample = @fabs(@as(f64, @floatFromInt(raw_sample)) / @as(f64, @floatFromInt(std.math.minInt(i16))));

            const bar_height = @as(c_int, @intFromFloat(@as(f64, @floatFromInt(panel_height)) * sample));
            const x = panel_x + @as(c_int, @intCast(x_offset));
            const y = panel_y + panel_height - bar_height;

            rl.DrawRectangle(x, y, 1, bar_height, bar_color);
        }
    }

    fn draw(fft: FFT) void {
        fft.draw_background();
        fft.draw_axes();
        fft.draw_graph();
    }

    fn deinit(fft: *FFT) void {
        fft.samples.deinit();
    }

    fn set_data(fft: *FFT, sample_rate: u32, samples: []const f64) !void {
        // TODO: swap in new data
        _ = fft;
        _ = sample_rate;
        _ = samples;
    }
};
