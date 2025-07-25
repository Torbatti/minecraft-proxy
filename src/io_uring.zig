pub const IoUringOps = enum(u8) {
    accept,
    accept_direct,
    accept_multishot,
    bind,
    close,
    close_direct,
    connect,
    epoll_ctl,
    nop,
    openat,
    openat_direct,
    poll_add,
    poll_remove,
    poll_update,
    read,
    recv,
    send,
    send_zc,
    setsockopt,
    shutdown,
    socket,
    timeout,
    timeout_remove,
    write,
    write_fixed,
    writev,
};
