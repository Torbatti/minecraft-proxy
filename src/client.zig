//
const std = @import("std");
const os = std.os;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;

//
pub const Client = struct {
    client_id: u64,
    //  add state : connected to target or not
};

//
pub const Message = struct {
    len: u32,
    pos: u32,
    buf: []u8,
    client: u64,
};

//
pub const Clients = struct {
    client_count: u16,

    clients: []Client,

    client_out_fds: []posix.socket_t,
    client_in_fds: []posix.socket_t,

    msg_from_client: []Message,
    msg_from_target: []Message,

    const self = @This();

    pub fn init(allocator: std.mem.Allocator, max_client: u16) !Clients {
        const clients: []Client = try allocator.alloc(Client, max_client);

        const client_out_fds: []posix.socket_t = try allocator.alloc(posix.socket_t, max_client);
        const client_in_fds: []posix.socket_t = try allocator.alloc(posix.socket_t, max_client);

        const msg_from_client: []Message = try allocator.alloc(Message, max_client);
        const msg_from_target: []Message = try allocator.alloc(Message, max_client);

        var clients_return: []Clients = try allocator.alloc(Clients, 1);

        clients_return[0] = Clients{
            .client_count = 0,
            .client_in_fds = client_in_fds,
            .client_out_fds = client_out_fds,
            .clients = clients,
            .msg_from_client = msg_from_client,
            .msg_from_target = msg_from_target,
        };

        return clients_return[0];
    }

    // use arena allocator instead xd?
    // pub fn deinit() !void {}
};
