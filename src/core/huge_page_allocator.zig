const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const maxInt = std.math.maxInt;
const assert = std.debug.assert;
const native_os = builtin.os.tag;
const windows = std.os.windows;
const linux = std.os.linux;
const posix = std.posix;

pub const vtable = Allocator.VTable{
    .alloc = alloc,
    .resize = Allocator.noResize,
    .free = free,
};

fn alloc(_: *anyopaque, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
    _ = ra;
    _ = log2_align;
    assert(n > 0);
    
    const page_size: u29 = if (n >= 500 * 1024) 2 * 1024 * 1024 else mem.page_size;
    
    if (n > maxInt(usize) - (page_size - 1)) return null;

    if (native_os == .windows) {
        const addr = windows.VirtualAlloc(
            null,

            // VirtualAlloc will round the length to a multiple of page size.
            // VirtualAlloc docs: If the lpAddress parameter is NULL, this value is rounded up to the next page boundary
            n,

            windows.MEM_COMMIT | windows.MEM_RESERVE,
            windows.PAGE_READWRITE,
        ) catch return null;
        return @ptrCast(addr);
    }

    const aligned_len = mem.alignForward(usize, n, page_size);
    const hint = @atomicLoad(@TypeOf(std.heap.next_mmap_addr_hint), &std.heap.next_mmap_addr_hint, .unordered);
    
    var slice: []align(4096) u8 = &[0]u8{};
    
    if (builtin.os.tag == .linux and page_size == 2 * 1024 * 1024) {
        const wtf_zig_map_linux = linux.MAP{
            .TYPE = .PRIVATE,
            .ANONYMOUS = true,
            .HUGETLB = true,
        };
        const HUGETLB_FLAG_ENCODE_SHIFT = 26;
        const specify_what_huge_page_flavor = @as(u32, 21) << HUGETLB_FLAG_ENCODE_SHIFT;
        const my_flags: linux.MAP = @bitCast(specify_what_huge_page_flavor | @as(u32, @bitCast(wtf_zig_map_linux)));
        std.log.err("My flags: {any}", .{my_flags});
        slice = posix.mmap(
            hint,
            aligned_len,
            posix.PROT.READ | posix.PROT.WRITE,
            my_flags,
            -1,
            0,
        ) catch &[0]u8{};
    }
    slice = posix.mmap(
        hint,
        aligned_len,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return null;
    
    assert(mem.isAligned(@intFromPtr(slice.ptr), page_size));
    
    const new_hint: [*]align(mem.page_size) u8 = @alignCast(slice.ptr + aligned_len);
    _ = @cmpxchgStrong(@TypeOf(std.heap.next_mmap_addr_hint), &std.heap.next_mmap_addr_hint, hint, new_hint, .monotonic, .monotonic);
    return slice.ptr;
}

fn free(_: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = log2_buf_align;
    _ = return_address;

    if (native_os == .windows) {
        windows.VirtualFree(slice.ptr, 0, windows.MEM_RELEASE);
    } else {
        const page_size: u29 = if (slice.len >= 500 * 1024) 2 * 1024 * 1024 else mem.page_size;
        const buf_aligned_len = mem.alignForward(usize, slice.len, page_size);
        posix.munmap(@alignCast(slice.ptr[0..buf_aligned_len]));
    }
}