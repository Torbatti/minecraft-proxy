//
const std = @import("std");
const os = std.os;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;

//
const IoUring = std.os.linux.IoUring;
const io_uring_sqe = std.os.linux.io_uring_sqe;
const io_uring_cqe = std.os.linux.io_uring_cqe;

//
const io_uring = @import("io_uring.zig");
const IoUringOps = io_uring.IoUringOps;

//
const listener = @import("listener.zig");

//
const client = @import("client.zig");
const Client = client.Client;
const Clients = client.Clients;
const Message = client.Message;

//
const QUEUE_DEPTH = 128;

pub const ProxyPiece = enum(u8) {
    listener,
    client_in,
    client_out,
    target,
};

const PACKET_SIZE = 2097151 + 3;

pub fn main() !void {
    //
    // Listener Setup
    //

    const listener_host = "127.0.0.1";
    const listener_port: u16 = 16424;
    const listener_fd = try listener.listener_setup(
        listener_host,
        listener_port,
    );
    defer posix.close(listener_fd);

    //
    // IoUring Ring
    //

    var ring = try IoUring.init(QUEUE_DEPTH, 0);
    defer ring.deinit();

    //
    // Allocators
    //

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    //
    // Clients
    //

    var clients = try Clients.init(arena_allocator, 32);

    // user_data = [32bits for cqe.res][16bits for id/client_id][8bit for target/client_in/client_out/listener][8bits for ops]
    while (true) {

        // const user_data: u64 =
        //             (0 << 32) +
        //             (0 << 16) +
        //             (0 << 8) +
        //             0;

        if (clients.client_count == 0) {
            const time_out = os.linux.kernel_timespec{
                .sec = 0,
                .nsec = 250,
            };
            _ = try ring.timeout(0, &time_out, 1, 0);
            _ = try ring.submit_and_wait(1);
        }

        const listener_accept_user_data: u64 =
            (0 << 32) +
            (0 << 16) +
            (@as(u64, @intFromEnum(ProxyPiece.listener)) << 8) +
            @as(u64, @intFromEnum(IoUringOps.accept)); // multishot/normal accept

        _ = try ring.accept_multishot(
            listener_accept_user_data,
            listener_fd,
            null,
            null,
            posix.SOCK.NONBLOCK,
        );

        // _ = try ring.submit_and_wait(1);

        var i: u16 = 0;

        while (i < clients.client_count) {
            const clientout_recv_user_data: u64 =
                (0 << 32) +
                (@as(u64, @intCast(i)) << 16) +
                (@as(u64, @intFromEnum(ProxyPiece.client_out)) << 8) +
                @as(u64, @intFromEnum(IoUringOps.recv));

            const target_recv_user_data: u64 =
                (0 << 32) +
                (@as(u64, @intCast(i)) << 16) +
                (@as(u64, @intFromEnum(ProxyPiece.client_in)) << 8) +
                @as(u64, @intFromEnum(IoUringOps.recv));

            const client_recv_buf = try arena_allocator.alloc(u8, PACKET_SIZE);
            const target_recv_buf = try arena_allocator.alloc(u8, PACKET_SIZE);

            var messages: []Message = try arena_allocator.alloc(Message, 2);
            messages[0] = Message{
                .buf = client_recv_buf,
                .client = i,
                .len = 0,
                .pos = 0,
            };
            messages[1] = Message{
                .buf = target_recv_buf,
                .client = i,
                .len = 0,
                .pos = 0,
            };
            clients.msg_from_client[i] = messages[0];
            clients.msg_from_target[i] = messages[1];

            _ = try ring.recv(
                clientout_recv_user_data,
                clients.client_out_fds[i],
                IoUring.RecvBuffer{ .buffer = client_recv_buf },
                0,
            );

            _ = try ring.recv(
                target_recv_user_data,
                clients.client_in_fds[i],
                IoUring.RecvBuffer{ .buffer = target_recv_buf },
                0,
            );

            i += 1;
        }
        i = 0;

        _ = try ring.submit();

        try handle_cqe(&ring, arena_allocator, &clients);
        std.debug.print("\n0) clients.client_count: {any}\n", .{clients.client_count});
    }
}

pub fn handle_cqe(
    ring: *IoUring,
    allocator: std.mem.Allocator,
    clients: *Clients,
) !void {
    // DUPLICATES!!
    const socket_type = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
    const socket_protocol = posix.IPPROTO.TCP;
    const listener_host = "127.0.0.1";
    const target_host = "127.0.0.1";
    const target_port: u16 = 25565;

    //
    const cq_ready = ring.cq_ready();
    std.debug.print("\n0) cq_ready: {any}\n", .{cq_ready});

    var i: u16 = 0;
    while (i < cq_ready) {
        const cqe = try ring.copy_cqe();

        // TODO: handle failed cqes
        // cqe failed or incomplete
        // if (cqe.res == 0) continue; // no error?

        std.debug.print("\n0) io_op tagname: {s}\n", .{@tagName(@as(IoUringOps, @enumFromInt((cqe.user_data << 56) >> 56)))});
        std.debug.print("0) proxy_piece tagname:{s}\n", .{@tagName(@as(ProxyPiece, @enumFromInt((cqe.user_data << 48) >> 56)))});
        std.debug.print("0) cqe.user_data:{any}\n", .{cqe.user_data});
        std.debug.print("0) cqe.res:{any}\n", .{cqe.res});

        if (cqe.res < 0) {
            std.debug.print("-1) cqe failed!\n", .{});

            continue;
        }

        if (cqe.res == 0) {
            std.debug.print("0) cqe UnKnown!\n", .{});
            // if (IoUringOps.accept == @as(IoUringOps, @enumFromInt((cqe.user_data << 56) >> 56))) {} else {
            //     continue;
            // }
            // continue;
        }

        std.debug.print("1) cqe passed!\n", .{});

        // user_data = [32bits for cqe.res][16bits for id/client_id][8bit for target/client_in/client_out/listener][8bits for ops]
        switch (@as(IoUringOps, @enumFromInt((cqe.user_data << 56) >> 56))) {
            IoUringOps.accept => {
                std.debug.print("0) accept next action started!\n", .{});

                const client_in_address = try net.Address.parseIp(listener_host, 0);

                const client_out_fd_ptr = try allocator.alloc(posix.socket_t, 1);
                client_out_fd_ptr[0] = cqe.res;
                const client_out_fd = client_out_fd_ptr[0];
                clients.client_out_fds[0] = client_out_fd;

                const clientin_socket_user_data: u64 =
                    (0 << 32) +
                    (@as(u64, clients.client_count) << 16) +
                    (@as(u64, @intFromEnum(ProxyPiece.client_in)) << 8) +
                    @as(u64, @intFromEnum(IoUringOps.socket));

                clients.client_count = clients.client_count + 1;
                std.debug.print("clients.client_count: {any}\n", .{clients.client_count});

                _ = try ring.socket(
                    clientin_socket_user_data,
                    client_in_address.any.family,
                    socket_type,
                    socket_protocol,
                    0,
                );
            },

            IoUringOps.socket => {
                std.debug.print("0) socket next action started!\n", .{});

                const target_address = try net.Address.parseIp(target_host, target_port);

                const client_in_fd = cqe.res;
                clients.client_in_fds[@as(u16, @intCast((cqe.user_data << 32) >> 48))] = client_in_fd;

                const clientin_connect_user_data: u64 =
                    (0 << 32) +
                    (@as(u64, @intCast(cqe.user_data)) << 16) +
                    (@as(u64, @intFromEnum(ProxyPiece.client_in)) << 8) +
                    @as(u64, @intFromEnum(IoUringOps.connect));

                // (@as(u64, @intFromEnum(IoUringOps.connect)) << 56) + (((cqe.user_data << 8) >> 8)),
                _ = try ring.connect(
                    clientin_connect_user_data,
                    client_in_fd,
                    &target_address.any,
                    target_address.getOsSockLen(),
                );
            },

            IoUringOps.connect => {
                std.debug.print("0) connect next action started!\n", .{});
                //
            },

            IoUringOps.recv => {
                std.debug.print("0) recv next action started!\n", .{});

                const recv_from: ProxyPiece = @as(ProxyPiece, @enumFromInt((cqe.user_data << 48) >> 56));
                const recv_len = @as(u32, @intCast(cqe.res));

                std.debug.print("1) recv next action started!\n", .{});
                const client_id: u16 = @as(u16, @intCast((cqe.user_data << 32) >> 48));
                var send_fd: posix.socket_t = undefined;

                std.debug.print("2) recv next action started!\n", .{});
                const send_buf = try allocator.alloc(u8, recv_len);

                var send_user_data: u64 = undefined;

                std.debug.print("3) recv next action started!\n", .{});
                // TODO: add user_data for recovering
                if (recv_from == ProxyPiece.client_out) {
                    send_user_data =
                        (0 << 32) +
                        (@as(u64, @intCast(client_id)) << 16) +
                        (@as(u64, @intFromEnum(ProxyPiece.client_in)) << 8) +
                        @as(u64, @intFromEnum(IoUringOps.send));

                    @memcpy(send_buf[0..], clients.msg_from_client[client_id].buf[0..recv_len]);
                    send_fd = clients.client_in_fds[client_id]; // recv from outside send to target

                } else if (recv_from == ProxyPiece.client_in) {
                    send_user_data =
                        (0 << 32) +
                        (@as(u64, @intCast(client_id)) << 16) +
                        (@as(u64, @intFromEnum(ProxyPiece.client_out)) << 8) +
                        @as(u64, @intFromEnum(IoUringOps.send));

                    @memcpy(send_buf[0..], clients.msg_from_target[client_id].buf[0..recv_len]);
                    send_fd = clients.client_out_fds[client_id]; // recv from target send to outside

                } else {
                    @panic("recv like this should not have happened!");
                }

                std.debug.print("4) recv next action started!\n", .{});
                _ = try ring.send(
                    0,
                    send_fd,
                    send_buf,
                    0,
                );
                std.debug.print("5) recv next action started!\n", .{});
            },

            IoUringOps.send => {
                std.debug.print("0) send next action started!\n", .{});
            },

            else => {
                std.debug.print("0) else next action started!\n", .{});
                @panic("");
            },
        }
        i += 1;
    }
    _ = try ring.submit();
}
