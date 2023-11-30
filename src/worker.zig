const std = @import("std");
const builtin = @import("builtin");

const httpz = @import("httpz.zig");
const Config = httpz.Config;
const Request = httpz.Request;
const Response = httpz.Response;

const Conn = @import("conn.zig").Conn;

const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Stream = std.net.Stream;
const NetConn = std.net.StreamServer.Connection;

const os = std.os;
const net = std.net;
const log = std.log.scoped(.httpz);

pub fn Worker(comptime S: type) type {
	return struct {
		server: S,

		// KQueue or Epoll, depending on the platform
		loop: Loop,

		// all data we can allocate upfront and re-use from request to request
		req_state: Request.State,

		// all data we can allocate upfront and re-use from request ot request (for the response)
		res_state: Response.State,

		// every request and response will be given an allocator from this arena
		arena: *ArenaAllocator,

		// allocator for httpz internal allocations
		httpz_allocator: Allocator,

		// an linked list of Conn objects that we're currently monitoring
		conn_list: Conn.List,

		// the maximum connection a worker should manage, we won't accept more than this
		max_conn: usize,

		// pool for creating Conn
		conn_pool: std.heap.MemoryPool(Conn),

		keepalive_timeout: u32,

		const Self = @This();

		const Loop = switch (builtin.os.tag) {
			.macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => KQueue,
			.linux => EPoll,
			else => @compileError("not supported"),
		};

		pub fn init(httpz_allocator: Allocator, app_allocator: Allocator, server: S, config: *const Config) !Self {
			const arena = try httpz_allocator.create(ArenaAllocator);
			arena.* = ArenaAllocator.init(app_allocator);
			errdefer httpz_allocator.destroy(arena);

			var req_state = try Request.State.init(httpz_allocator, config.request);
			errdefer req_state.deinit(httpz_allocator);

			var res_state = try Response.State.init(httpz_allocator, config.response);
			errdefer res_state.deinit(httpz_allocator);

			const loop = try Loop.init();
			errdefer loop.deinit();

			return .{
				.arena = arena,
				.loop = loop,
				.max_conn = config.pool.worker_max_conn orelse 512,
				.conn_list = .{},
				.conn_pool = std.heap.MemoryPool(Conn).init(httpz_allocator),
				.server = server,
				.req_state = req_state,
				.res_state = res_state,
				.httpz_allocator = httpz_allocator,
				.keepalive_timeout = config.keepalive.timeout orelse 4294967295,
			};
		}

		pub fn deinit(self: *Self) void {
			const httpz_allocator = self.httpz_allocator;

			var conn = self.conn_list.head;
			while (conn) |c| {
				c.stream.close();
				conn = c.next;
			}

			self.req_state.deinit(httpz_allocator);
			self.res_state.deinit(httpz_allocator);

			self.arena.deinit();
			self.conn_pool.deinit();
			httpz_allocator.destroy(self.arena);

			self.loop.deinit();
		}

		pub fn run(self: *Self, listener: *net.StreamServer, signal: os.fd_t) void {
			std.os.maybeIgnoreSigpipe();

			self.loop.add(listener.sockfd.?, 0) catch |err| {
				log.err("Failed to add monitor to listening socket: {}", .{err});
				return;
			};

			self.loop.add(signal, 1) catch |err| {
				log.err("Failed to add monitor to signal pipe: {}", .{err});
				return;
			};

			const keepalive_timeout = self.keepalive_timeout;

			while (true) {
				var it = self.loop.wait() catch |err| {
					log.err("Failed to wait on events: {}", .{err});
					std.time.sleep(std.time.ns_per_s);
					continue;
				};
				const now = std.time.microTimestamp();

				while (it.next()) |data| {
					if (data == 0) {
						self.accept(listener, now) catch |err| {
							log.err("Failed to accept connection: {}", .{err});
							std.time.sleep(std.time.ns_per_s);
						};
						continue;
					}

					if (data == 1) {
						// our control signal, we're being told to stop,
						return;
					}

					const managed: *align(8) Conn = @ptrFromInt(data);
					var will_close = (now - managed.last_request) > keepalive_timeout;

					if (self.handleRequest(managed, will_close)) {
						managed.last_request = now;
					} else {
						// handle request had an error
						will_close = true;
					}

					if (will_close) {
						managed.stream.close();
						self.conn_list.remove(managed);
						self.conn_pool.destroy(managed);
					}
				}
			}
		}

		fn accept(self: *Self, listener: *net.StreamServer, now: i64) !void {
			var conn_list = &self.conn_list;
			var len = conn_list.len;

			const max_conn = self.max_conn;

			while (len < max_conn) {
				const conn = listener.accept() catch |err| {
					return if (err == error.WouldBlock) {} else err;
				};

				const managed = try self.conn_pool.create();
				managed.* = .{
					.last_request = now,
					.stream = conn.stream,
					.address = conn.address,
				};
				try self.loop.add(conn.stream.handle, @intFromPtr(managed));
				conn_list.insert(managed);
				len += 1;
			}
		}

		pub fn handleRequest(self: *Self, conn: *Conn, will_close: bool) bool {
			const arena = self.arena;
			const server = self.server;

			var req_state = &self.req_state;
			var res_state = &self.res_state;

			req_state.reset();
			res_state.reset();

			defer _ = arena.reset(.free_all);

			const aa = arena.allocator();
			var res = Response.init(aa, res_state, conn.stream);

			var req = Request.parse(aa, req_state, conn) catch |err| {
				switch (err) {
					error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine => {
						res.status = 400;
						res.body = "Invalid Request";
					},
					error.HeaderTooBig => {
						res.status = 431;
						res.body = "Request header is too big";
					},
					else => return false,
				}
				res.write() catch {};
				return false;
			};

			req.keepalive = !will_close;
			if (!server.handle(&req, &res)) {
				return false;
			}
			req.drain() catch return false;
			return true;
		}
	};
}

const KQueue = struct {
	q: i32,
	change_count: usize,
	change_buffer: [8]Kevent,
	event_list: [32]Kevent,

	const Kevent = std.os.Kevent;

	fn init() !KQueue {
		return .{
			.q = try std.os.kqueue(),
			.change_count = 0,
			.change_buffer = undefined,
			.event_list = undefined,
		};
	}

	fn deinit(self: KQueue) void {
		std.os.close(self.q);
	}

	fn add(self: *KQueue, fd: os.fd_t, data: usize) !void {
		return self.change(.{
			.ident = @intCast(fd),
			.filter = os.system.EVFILT_READ,
			.flags = os.system.EV_ADD | os.system.EV_ENABLE,
			.fflags = 0,
			.data = 0,
			.udata = data,
		});
	}

	fn change(self: *KQueue, event: Kevent) !void {
		var change_count = self.change_count;
		var change_buffer = &self.change_buffer;

		if (change_count == change_buffer.len) {
			// calling this with an empty event_list will return immediate
			_ = try std.os.kevent(self.q, change_buffer, &[_]Kevent{}, null);
			change_count = 0;
		}
		change_buffer[change_count] = event ;
		self.change_count = change_count + 1;
	}

	fn wait(self: *KQueue) !Iterator {
		const event_list = &self.event_list;
		const event_count = try std.os.kevent(self.q, self.change_buffer[0..self.change_count], event_list, null);
		self.change_count = 0;

		return .{
			.index = 0,
			.events = event_list[0..event_count],
		};
	}

	const Iterator = struct {
		index: usize,
		events: []Kevent,

		fn next(self: *Iterator) ?usize{
			const index = self.index;
			const events = self.events;
			if (index == events.len) {
				return null;
			}
			self.index = index + 1;
			return self.events[index].udata;
		}
	};
};

const EPoll = struct {
	q: i32,
	event_list: [32]EpollEvent,

	const EpollEvent = std.os.linux.epoll_event;

	fn init() !EPoll {
		return .{
			.event_list = undefined,
			.q = try std.os.epoll_create1(0),
		};
	}

	fn deinit(self: EPoll) void {
		std.os.close(self.q);
	}

	fn add(self: *EPoll, fd: os.fd_t, user_data: usize) !void {
		var event = os.linux.epoll_event{
			.events = os.linux.EPOLL.IN,
			.data = .{.ptr = user_data}
		};
		return std.os.epoll_ctl(self.q, os.linux.EPOLL.CTL_ADD, fd, &event);
	}

	fn wait(self: *EPoll) !Iterator {
		const event_list = &self.event_list;
		const event_count = std.os.epoll_wait(self.q, event_list, -1);
		return .{
			.index = 0,
			.events = event_list[0..event_count],
		};
	}

	const Iterator = struct {
		index: usize,
		events: []EpollEvent,

		fn next(self: *Iterator) ?usize{
			const index = self.index;
			const events = self.events;
			if (index == events.len) {
				return null;
			}
			self.index = index + 1;
			return self.events[index].data.ptr;
		}
	};
};