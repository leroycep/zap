const std = @import("std");
const expect = std.testing.expect;

const zio = @import("../../zap.zig").zio;
const zuma = @import("../../zap.zig").zuma;

pub const Socket = struct {
    inner: zio.backend.Socket,

    pub const Flags = zio.Flags;
    pub const Nonblock = zio.Nonblock;
    pub const Raw: zio.Flags = 1 << 1;
    pub const Tcp: zio.Flags = 1 << 2;
    pub const Udp: zio.Flags = 1 << 3;
    pub const Ipv4: zio.Flags = 1 << 4;
    pub const Ipv6: zio.Flags = 1 << 5;

    pub const Error = error{
        InvalidValue,
        InvalidState,
        OutOfResources,
    };

    pub fn new(flags: Flags) Error!@This() {
        const socket = try zio.backend.Socket.new(flags);
        return @This(){ .inner = socket };
    }

    pub fn close(self: *@This()) void {
        return self.inner.close();
    }

    pub inline fn fromHandle(handle: zio.Handle, flags: Flags) @This() {
        return @This(){ .inner = zio.backend.Socket.fromHandle(handle, flags) };
    }

    pub inline fn getHandle(self: @This()) zio.Handle {
        return self.inner.getHandle();
    }

    pub inline fn getTokenMask(self: *const @This(), comptime event_flags: zio.Event.Flags) usize {
        comptime std.debug.assert((event_flags & (zio.Event.Readable | zio.Event.Writeable)) != 0);
        return self.inner.getTokenMask(event_flags);
    }

    const Linger = zio.backend.Socket.Linger;
    pub const Option = union(enum) {
        Debug: bool, // SO_DEBUG
        Linger: Linger, // SO_LINGER
        Broadcast: bool, // SO_BROADCAST
        Reuseaddr: bool, // SO_REUSEADDR
        Keepalive: bool, // SO_KEEPALIVE
        Oobinline: bool, // SO_OOBINLINE
        Tcpnodelay: bool, // TCP_NODELAY
        RecvBufMax: c_int, // SO_RCVBUF
        RecvBufMin: c_int, // SO_RCVLOWAT
        RecvTimeout: c_int, // SO_RCVTIMEO
        SendBufMax: c_int, // SO_SNDBUF
        SendBufMin: c_int, // SO_SNDLOWAT
        SendTimeout: c_int, // SO_SNDTIMEO
    };

    pub const OptionError = error{
        InvalidState,
        InvalidValue,
        InvalidHandle,
    };

    pub fn setOption(self: *@This(), option: Option) OptionError!void {
        return self.inner.setOption(option);
    }

    pub fn getOption(self: @This(), option: *Option) OptionError!void {
        return self.inner.getOption(option);
    }

    pub const BindError = error{
        AddressInUse,
        InvalidState,
        InvalidHandle,
        InvalidAddress,
    };

    pub fn bind(self: *@This(), address: *const zio.Address) BindError!void {
        return self.inner.bind(address);
    }

    pub const ListenError = error{
        AddressInUse,
        InvalidState,
        InvalidHandle,
    };

    pub fn listen(self: *@This(), backlog: c_uint) ListenError!void {
        return self.inner.listen(backlog);
    }

    pub const ConnectError = zio.Error.Set || RawConnectError;
    pub const RawConnectError = error{
        TimedOut,
        InvalidState,
        InvalidHandle,
        InvalidAddress,
        AlreadyConnected,
    };

    pub fn connect(self: *@This(), address: *const zio.Address, token: usize) ConnectError!void {
        return self.inner.connect(address, token);
    }

    pub const AcceptError = zio.Error.Set || RawAcceptError;
    pub const RawAcceptError = error{
        InvalidState,
        InvalidHandle,
        InvalidAddress,
        OutOfResources,
    };

    pub fn accept(self: *@This(), flags: Flags, incoming: *zio.Address.Incoming, token: usize) AcceptError!void {
        return self.inner.accept(flags, incoming, token);
    }

    pub const DataError = zio.Error.Set || RawDataError;
    pub const RawDataError = error{
        InvalidState,
        InvalidValue,
        InvalidHandle,
        BufferTooLarge,
        OutOfResources,
    };

    /// Convert an array of zig buffers into backend buffers
    threadlocal var buffer_cache: [256]zio.Buffer = undefined;
    fn toBackendBuffers(buffers: var) []zio.backend.Buffer {
        // TODO: https://github.com/ziglang/zig/issues/3433
        const cache = @intToPtr([*]zio.Buffer, @ptrToInt(&buffer_cache[0]))[0..buffer_cache.len];
        const zio_buffers = cache[0..std.math.min(cache.len, buffers.len)];
        for (zio_buffers) |*buffer, index|
            buffer.* = zio.Buffer.fromBytes(buffers[index]);
        return @ptrCast([*]zio.backend.Buffer, zio_buffers.ptr)[0..zio_buffers.len];
    }

    /// Alias for `read()`
    pub fn recv(self: *@This(), buffer: []u8, token: usize) DataError!usize {
        return self.read(buffer, token);
    }

    /// Alias for `write()`
    pub fn send(self: *@This(), buffer: []const u8, token: usize) DataError!usize {
        return self.write(buffer, token);
    }

    /// Alias for `readv()` using one buffer
    pub fn read(self: *@This(), buffer: []u8, token: usize) DataError!usize {
        var buffers = [_][]u8{buffer};
        return self.readv(buffers[0..], token);
    }

    /// Alias for `writev()` using one buffer
    pub fn write(self: *@This(), buffer: []const u8, token: usize) DataError!usize {
        var buffers = [_][]const u8{buffer};
        return self.writev(buffers[0..], token);
    }

    /// Alias for `recvmsg()` with a null address
    pub fn readv(self: *@This(), buffers: []const []u8, token: usize) DataError!usize {
        return self.recvmsg(null, buffers, token);
    }

    /// Alias for `sendmsg()` with a null address
    pub fn writev(self: *@This(), buffers: []const []const u8, token: usize) DataError!usize {
        return self.sendmsg(null, buffers, token);
    }

    /// Alias for `recvmsg()` using one buffer
    pub fn recvfrom(self: *@This(), address: *zio.Address, buffer: []u8, token: usize) DataError!usize {
        var buffers = [_][]u8{buffer};
        return self.recvmsg(address, buffers[0..], token);
    }

    /// Alias for `sendmsg()` using one buffer
    pub fn sendto(self: *@This(), address: *const zio.Address, buffer: []const u8, token: usize) DataError!usize {
        var buffers = [_][]const u8{buffer};
        return self.sendmsg(address, buffers[0..], token);
    }

    /// Tries to read data over the given socket into an array of buffers.
    /// The optional address specifies the IP address the data is directed to.
    /// The token represents a contiuation for non blocking IO which can be retrieved
    /// from `zio.Event.getToken()` after polling for events using `zio.Event.Poller.poll()`.
    /// If the token is 0, the read request is performed synchronously and blocks until completion.
    pub fn recvmsg(self: *@This(), address: ?*zio.Address, buffers: []const []u8, token: usize) DataError!usize {
        return self.inner.recvmsg(address, toBackendBuffers(buffers), token);
    }

    /// Tries to write data over the given socket using an array of buffers.
    /// The optional address specifies the IP address the data is directed to.
    /// The token represents a contiuation for non blocking IO which can be retrieved
    /// from `zio.Event.getToken()` after polling for events using `zio.Event.Poller.poll()`.
    /// If the token is 0, the read request is performed synchronously and blocks until completion.
    pub fn sendmsg(self: *@This(), address: ?*const zio.Address, buffers: []const []const u8, token: usize) DataError!usize {
        return self.inner.sendmsg(address, toBackendBuffers(buffers), token);
    }
};

const Ipv4Address = struct {
    pub const Flag = Socket.Ipv4;

    pub fn new(port: u16) !zio.Address {
        const host = try zio.Address.parseIpv4("localhost");
        return zio.Address.fromIpv4(host, port);
    }

    pub fn validate(address: zio.Address) bool {
        return address.isIpv4();
    }
};

const Ipv6Address = struct {
    pub const Flag = Socket.Ipv6;

    pub fn new(port: u16) !zio.Address {
        const host = try zio.Address.parseIpv6("::1");
        return zio.Address.fromIpv6(host, port, 0, 0);
    }

    pub fn validate(address: zio.Address) bool {
        return address.isIpv6();
    }
};

test "Socket (Tcp) Blocking Ipv4 + Ipv6" {
    const rng = zuma.Thread.getRandom();
    try testBlockingTcp(Ipv4Address, rng.intRangeLessThanBiased(u16, 1024, 65535));
    try testBlockingTcp(Ipv6Address, rng.intRangeLessThanBiased(u16, 1024, 65535));
}

fn testBlockingTcp(comptime AddressType: type, port: u16) !void {
    // Create the server socket
    var server = try Socket.new(AddressType.Flag | Socket.Tcp);
    defer server.close();

    // Setup socket options for server handling
    try server.setOption(Socket.Option{ .SendTimeout = 1000 });
    try server.setOption(Socket.Option{ .RecvTimeout = 1000 });
    try server.setOption(Socket.Option{ .Reuseaddr = true });
    var option = Socket.Option{ .Reuseaddr = undefined };
    try server.getOption(&option);
    expect(option.Reuseaddr == true);

    // Allow the server socket to accept incoming connections
    var address = try AddressType.new(port);
    try server.bind(&address);
    try server.listen(1);

    // Create the client socket
    var client = try Socket.new(AddressType.Flag | Socket.Tcp);
    defer client.close();

    // Connect the client socket to the server socket
    try client.setOption(Socket.Option{ .SendTimeout = 1000 });
    try client.setOption(Socket.Option{ .RecvTimeout = 1000 });
    try client.setOption(Socket.Option{ .Tcpnodelay = true });
    address = try AddressType.new(port);
    try client.connect(&address, 0);

    // Accept the incoming client from the server
    var incoming = zio.Address.Incoming.new(try AddressType.new(port));
    try server.accept(AddressType.Flag | Socket.Tcp, &incoming, 0);
    expect(AddressType.validate(incoming.address));
    var server_client = incoming.getSocket(AddressType.Flag | Socket.Tcp);
    defer server_client.close();

    // send data from the servers client to the connected client
    // use sendto() to test that the address passed in is ignored for TCP sockets.
    const data = "Hello world";
    var transferred = try server_client.sendto(&incoming.address, data, 0);
    expect(transferred == data.len);

    // receive the data from the connected client which was sent by the server client
    // use recvfrom() to test that the address passed in is ignored for TCP sockets/
    var input_data: [data.len]u8 = undefined;
    transferred = try client.recvfrom(&incoming.address, input_data[0..], 0);
    expect(transferred == data.len);
    expect(std.mem.eql(u8, data, input_data[0..]));
}

test "Socket (Tcp) Non-Blocking Ipv4 + Ipv6" {
    const rng = zuma.Thread.getRandom();
    try testNonBlockingTcp(Ipv4Address, rng.intRangeLessThanBiased(u16, 1024, 65535));
    try testNonBlockingTcp(Ipv6Address, rng.intRangeLessThanBiased(u16, 1024, 65535));
}

fn testNonBlockingTcp(comptime AddressType: type, port: u16) !void {
    const data = "X" ** (5 * 1024);
    const flags = AddressType.Flag | Socket.Tcp | Socket.Nonblock;

    const Server = struct {
        server: zio.Socket,
        client: zio.Socket,
        client_sent: usize,
        incoming: zio.Address.Incoming,

        pub fn init(self: *@This(), poller: *zio.Event.Poller, addr_port: u16) !void {
            // Setup the server socket and register for Readable (incoming socket) & EdgeTrigger (dont reregister) events
            self.server = try Socket.new(flags);
            errdefer self.close();
            try self.server.setOption(Socket.Option{ .Reuseaddr = true });
            var address = try AddressType.new(addr_port);
            try self.server.bind(&address);
            try self.server.listen(1);
            try poller.register(
                self.server.getHandle(),
                zio.Event.Readable | zio.Event.EdgeTrigger,
                @ptrToInt(&self.server),
            );

            // Start accepting an incoming socket
            self.incoming = zio.Address.Incoming.new(try AddressType.new(addr_port));
            self.client_sent = 0;
            try self.handle_server(0, poller);
        }

        pub fn close(self: *@This()) void {
            self.server.close();
            self.client.close();
        }

        pub fn handle_server(self: *@This(), token: usize, poller: *zio.Event.Poller) !void {
            // ensure the token is correct semantic-wise
            const token_mask = self.server.getTokenMask(zio.Event.Readable);
            std.debug.assert(token == 0 or token & token_mask == token_mask);

            // Accept the incoming client
            _ = self.server.accept(flags, &self.incoming, token) catch |err| switch (err) {
                zio.Error.Pending => return,
                else => return err,
            };
            expect(AddressType.validate(self.incoming.address));

            // Setup the client & start sending data (see Client struct below)
            // Since all this client will do is send data, register for Writeable & EdgeTrigger for reason above.
            self.client = self.incoming.getSocket(flags);
            try self.client.setOption(Socket.Option{ .SendBufMax = 2048 });
            try self.client.setOption(Socket.Option{ .RecvBufMax = 2048 });
            try poller.register(
                self.client.getHandle(),
                zio.Event.Writeable | zio.Event.EdgeTrigger,
                @ptrToInt(&self.client),
            );
            try self.handle_client(0, poller);
        }

        pub fn handle_client(self: *@This(), io_token: usize, poller: *zio.Event.Poller) !void {
            // Keep sending data until its all received on the client side
            var token = io_token;
            while (self.client_sent < data.len) {
                // ensure the token is correct semantic-wise
                const token_mask = self.client.getTokenMask(zio.Event.Writeable);
                std.debug.assert(token == 0 or token & token_mask == token_mask);

                const buffer = data[0..(data.len - self.client_sent)];
                self.client_sent += self.client.send(buffer, token) catch |err| switch (err) {
                    zio.Error.Pending, zio.Error.Closed => return,
                    else => return err,
                };
                token = 0;
            }
        }
    };

    const Client = struct {
        socket: zio.Socket,
        received: usize,
        buffer: [2048]u8,
        connected: bool,

        // Create a client socket and start doing IO
        // Set the socket buffers as small as possible to force many fragmented reads to test non blocking.
        // Also start off with being registered for Writeable since that is equivalent to a Connect event.
        pub fn new(self: *@This(), poller: *zio.Event.Poller, addr_port: u16) !void {
            self.socket = try Socket.new(flags);
            errdefer self.close();
            try self.socket.setOption(Socket.Option{ .SendBufMax = 2048 });
            try self.socket.setOption(Socket.Option{ .RecvBufMax = 2048 });
            try poller.register(
                self.socket.getHandle(),
                zio.Event.Writeable | zio.Event.EdgeTrigger,
                @ptrToInt(&self.socket),
            );

            self.received = 0;
            self.connected = false;
            try self.handle(0, poller, addr_port);
        }

        pub fn close(self: *@This()) void {
            self.socket.close();
        }

        pub fn handle(self: *@This(), event_token: usize, poller: *zio.Event.Poller, addr_port: u16) !void {
            var token = event_token;
            // First, connect to the server socket
            while (!self.connected) {
                var address = try AddressType.new(addr_port);
                _ = self.socket.connect(&address, token) catch |err| switch (err) {
                    zio.Error.Pending => return,
                    else => return err,
                };
                self.connected = true;
                try poller.reregister(
                    self.socket.getHandle(),
                    zio.Event.Readable | zio.Event.EdgeTrigger,
                    @ptrToInt(&self.socket),
                );
                token = 0;
            }

            // Then, start receiving data from the server
            // Handle Error.InvalidToken since events could be for writer instead of reader
            while (self.received < data.len) {
                // ensure the token is correct semantic-wise
                const token_mask = self.socket.getTokenMask(zio.Event.Readable);
                std.debug.assert(token == 0 or token & token_mask == token_mask);

                self.received += self.socket.recv(self.buffer[0..], token) catch |err| switch (err) {
                    zio.Error.Pending => return,
                    else => return err,
                };
                token = 0;
            }
        }
    };

    // Create the event poller, server and client
    var server: Server = undefined;
    var client: Client = undefined;
    var poller = try zio.Event.Poller.new();
    defer poller.close();
    try server.init(&poller, port);
    defer server.close();
    try client.new(&poller, port);
    defer client.close();

    // listen and process events
    var events: [64]zio.Event = undefined;
    while (server.client_sent < data.len or client.received < data.len) {
        const socket_events = try poller.poll(events[0..], 500);
        if (socket_events.len == 0)
            return error.EventPollTimedOut;

        // dispatched based on the data registered by the poller
        for (socket_events) |event| {
            const user_data = event.readData(&poller);
            if (user_data == @ptrToInt(&server.server)) {
                try server.handle_server(event.getToken(), &poller);
            } else if (user_data == @ptrToInt(&server.client)) {
                try server.handle_client(event.getToken(), &poller);
            } else if (user_data == @ptrToInt(&client.socket)) {
                try client.handle(event.getToken(), &poller, port);
            }
        }
    }

    expect(server.client_sent == data.len);
    expect(client.received == data.len);
}