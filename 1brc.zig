const std = @import("std");
const windows = std.os.windows;

// ─────────────────────────────────────────────────────────────────────────────
//  TUNEABLE CONSTANTS
//  NUM_THREADS     : 8 ≈ 50 % of your 16-logical-CPU box
//  HASHMAP_CAPACITY: initial bucket count per thread (stations ≈ 400-500)
// ─────────────────────────────────────────────────────────────────────────────
const NUM_THREADS: usize = 8;
const HASHMAP_CAPACITY: u32 = 512;

// ─────────────────────────────────────────────────────────────────────────────
//  WIN32 MEMORY-MAPPING  (std.os.mmap does not exist on Windows)
// ─────────────────────────────────────────────────────────────────────────────
const PAGE_READONLY: windows.DWORD = 0x02;
const FILE_MAP_READ: windows.DWORD = 0x0004;

extern "kernel32" fn CreateFileMappingW(
    hFile: windows.HANDLE,
    lpAttr: ?*anyopaque,
    flProtect: windows.DWORD,
    dwMaxSizeHi: windows.DWORD,
    dwMaxSizeLo: windows.DWORD,
    lpName: ?[*:0]const u16,
) callconv(windows.WINAPI) ?windows.HANDLE;

extern "kernel32" fn MapViewOfFile(
    hMapping: windows.HANDLE,
    dwAccess: windows.DWORD,
    dwOffsetHi: windows.DWORD,
    dwOffsetLo: windows.DWORD,
    dwBytes: usize,
) callconv(windows.WINAPI) ?*anyopaque;

extern "kernel32" fn UnmapViewOfFile(
    lpBase: *anyopaque,
) callconv(windows.WINAPI) windows.BOOL;

// ─────────────────────────────────────────────────────────────────────────────
//  DATA TYPES
//  All temperatures are stored as integer tenths (×10):
//    28.3 °C  →  283   (i64)
//    -7.1 °C  →  -71   (i64)
// ─────────────────────────────────────────────────────────────────────────────
const Stats = struct {
    min: i64,
    max: i64,
    sum: i64,
    count: u64,
};

const StatsMap = std.StringHashMap(Stats);

// ─────────────────────────────────────────────────────────────────────────────
//  THREAD WORKER
//  KEY FIX: use map.get() (returns a copy) + map.put() to write back,
//  instead of getOrPut() + writing through value_ptr.
//  In ReleaseFast, getOrPut() can reallocate the table while returning a
//  pointer into the old allocation — the pointer becomes stale before the
//  write, silently leaving sum = 0.
// ─────────────────────────────────────────────────────────────────────────────
const WorkerArg = struct {
    data: []const u8,
    allocator: std.mem.Allocator,
};

fn worker(arg: WorkerArg, out: *StatsMap) void {
    out.* = StatsMap.init(arg.allocator);
    out.ensureTotalCapacity(HASHMAP_CAPACITY) catch |err| {
        std.debug.print("ensureTotalCapacity error: {}\n", .{err});
        return;
    };

    const d = arg.data;
    var i: usize = 0;

    while (i < d.len) {

        // Station name: scan to ';'
        const name_start = i;
        while (i < d.len and d[i] != ';') : (i += 1) {}
        const name = d[name_start..i];
        if (i >= d.len) break;
        i += 1; // skip ';'

        // Temperature: optional '-', digits + '.', stored as i64 tenths
        var neg: bool = false;
        if (i < d.len and d[i] == '-') {
            neg = true;
            i += 1;
        }

        var val: i64 = 0;
        while (i < d.len and d[i] != '\n' and d[i] != '\r') : (i += 1) {
            const c = d[i];
            if (c != '.') {
                val = val * 10 + @as(i64, @intCast(c - '0'));
            }
        }
        if (neg) val = -val;

        // Skip \r\n or \n
        while (i < d.len and (d[i] == '\r' or d[i] == '\n')) : (i += 1) {}

        if (name.len == 0) continue;

        // ── SAFE accumulation: get-copy → modify → put-back ───────────────
        //  Avoids any pointer-into-hash-table aliasing under optimisation.
        if (out.get(name)) |existing| {
            var s = existing; // s is a plain stack copy
            if (val < s.min) s.min = val;
            if (val > s.max) s.max = val;
            s.sum = s.sum + val;
            s.count = s.count + 1;
            out.put(name, s) catch continue;
        } else {
            out.put(name, Stats{
                .min = val,
                .max = val,
                .sum = val,
                .count = 1,
            }) catch continue;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────────────────────────────────────────

/// Advance past the next '\n' to keep chunk boundaries on whole lines.
fn nextLineStart(data: []const u8, pos: usize) usize {
    var i: usize = if (pos < data.len) pos else data.len;
    while (i < data.len and data[i] != '\n') : (i += 1) {}
    if (i < data.len) i += 1;
    return i;
}

/// Integer average (tenths ÷ count), rounded half-away-from-zero.
fn roundedAvg(sum: i64, count: u64) i64 {
    const c = @as(i64, @intCast(count));
    const half = @divTrunc(c, 2);
    return if (sum >= 0)
        @divTrunc(sum + half, c)
    else
        @divTrunc(sum - half, c);
}

/// Write an i64 tenths-value as "XX.X" (handles negative and zero).
fn writeTemp(w: anytype, v: i64) !void {
    var u: u64 = undefined;
    if (v < 0) {
        try w.writeByte('-');
        u = @intCast(-v);
    } else {
        u = @intCast(v);
    }
    try w.print("{d}.{d}", .{ u / 10, u % 10 });
}

// ─────────────────────────────────────────────────────────────────────────────
//  MAIN
// ─────────────────────────────────────────────────────────────────────────────
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);
    const path: []const u8 = if (argv.len > 1) argv[1] else "1brc.txt";

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    if (file_size == 0) {
        std.debug.print("File is empty.\n", .{});
        return;
    }

    // ── Windows memory-map ────────────────────────────────────────────────────
    const mapping = CreateFileMappingW(
        file.handle,
        null,
        PAGE_READONLY,
        0,
        0,
        null,
    ) orelse return error.CreateFileMappingFailed;
    defer windows.CloseHandle(mapping);

    const raw_ptr = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0) orelse return error.MapViewOfFileFailed;
    defer _ = UnmapViewOfFile(raw_ptr);

    const data: []const u8 = @as([*]const u8, @ptrCast(raw_ptr))[0..file_size];

    // ── Split into N newline-aligned chunks ───────────────────────────────────
    const n = @min(NUM_THREADS, file_size);
    var chunk_starts: [NUM_THREADS]usize = undefined;
    var chunk_ends: [NUM_THREADS]usize = undefined;

    for (0..n) |idx| {
        const approx = file_size / n * idx;
        chunk_starts[idx] = if (idx == 0) 0 else nextLineStart(data, approx);
    }
    for (0..n) |idx| {
        chunk_ends[idx] = if (idx + 1 == n) file_size else chunk_starts[idx + 1];
    }

    // ── Per-thread arena allocators (no lock contention) ─────────────────────
    var arenas: [NUM_THREADS]std.heap.ArenaAllocator = undefined;
    for (arenas[0..n]) |*a| a.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer for (arenas[0..n]) |*a| a.deinit();

    // ── Spawn threads ─────────────────────────────────────────────────────────
    var maps: [NUM_THREADS]StatsMap = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;

    for (0..n) |idx| {
        const arg = WorkerArg{
            .data = data[chunk_starts[idx]..chunk_ends[idx]],
            .allocator = arenas[idx].allocator(),
        };
        threads[idx] = try std.Thread.spawn(.{}, worker, .{ arg, &maps[idx] });
    }
    for (threads[0..n]) |t| t.join();

    // ── Merge per-thread maps (same safe get-copy + put pattern) ─────────────
    var final = StatsMap.init(alloc);
    defer final.deinit();
    try final.ensureTotalCapacity(HASHMAP_CAPACITY);

    for (maps[0..n]) |*m| {
        var it = m.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const e = entry.value_ptr.*; // copy by value
            if (final.get(key)) |existing| {
                var s = existing;
                if (e.min < s.min) s.min = e.min;
                if (e.max > s.max) s.max = e.max;
                s.sum = s.sum + e.sum;
                s.count = s.count + e.count;
                try final.put(key, s);
            } else {
                try final.put(key, e);
            }
        }
    }

    // ── Sort station names alphabetically ─────────────────────────────────────
    var names = try alloc.alloc([]const u8, final.count());
    defer alloc.free(names);
    {
        var it = final.keyIterator();
        var idx: usize = 0;
        while (it.next()) |k| {
            names[idx] = k.*;
            idx += 1;
        }
    }
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // ── Buffered output ───────────────────────────────────────────────────────
    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const w = bw.writer();

    for (names) |name| {
        const s = final.get(name).?;
        const avg = roundedAvg(s.sum, s.count);
        try w.writeAll(name);
        try w.writeAll(": ");
        try writeTemp(w, s.min);
        try w.writeByte('/');
        try writeTemp(w, avg);
        try w.writeByte('/');
        try writeTemp(w, s.max);
        try w.writeByte('\n');
    }
    try bw.flush();
}
