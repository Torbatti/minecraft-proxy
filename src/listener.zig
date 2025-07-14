//
const std = @import("std");
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;

pub const Listener = struct {
    pub const setup = listener_setup;
};

pub fn listener_setup(
    host: []const u8,
    port: u16,
) !posix.socket_t {
    const listener_address = try net.Address.parseIp(
        host,
        port,
    );

    const listener_socket_type = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
    const listener_socket_protocol = posix.IPPROTO.TCP;

    const listener_fd = try posix.socket(
        listener_address.any.family,
        listener_socket_type,
        listener_socket_protocol,
    );

    try posix.setsockopt(
        listener_fd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    try posix.bind(
        listener_fd,
        &listener_address.any,
        listener_address.getOsSockLen(),
    );

    try posix.listen(
        listener_fd,
        128,
    );

    return listener_fd;
}
