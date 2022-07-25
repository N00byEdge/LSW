const std = @import("std");

var tp_alloc = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.page_allocator };
var work_alloc = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.page_allocator };

const Work = fn(
    CallbackInstance,
    Context,
    *anyopaque,
) callconv(.Win64) void;

const Context = u64;
const CallbackInstance = u64;

const TPWork = struct {
    queue_node: std.TailQueue(void).Node,
    callback_environ: CallbackInstance,
    context: Context,
    work: ?Work,
};

const WorkQueue = struct {
    sema: std.Thread.Semaphore = .{},
    pool_mutex: std.Thread.Mutex = .{},
    queue: std.TailQueue(void) = .{},

    pub fn pop(self: *@This()) *TPWork {
        self.sema.wait();

        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        return @fieldParentPtr(TPWork, "queue_node", self.queue.pop() orelse unreachable);
    }

    pub fn push(self: *@This(), w: *TPWork) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        self.queue.append(&w.queue_node);
        self.sema.post();
    }
};

pub fn allocWork(work: ?Work, context: Context, callback_environ: CallbackInstance) !*TPWork {
    const ptr = try work_alloc.allocator().create(TPWork);
    ptr.* = .{
        .queue_node = undefined,
        .work = work,
        .context = context,
        .callback_environ = callback_environ,
    };
    return ptr;
}

pub fn allocPool() !*ThreadPool {
    const p = try tp_alloc.allocator().create(ThreadPool);
    p.* = .{};
    return p;
}

pub const ThreadPool = struct {
    running_threads: usize = 0,
    queue: WorkQueue = .{},

    pub fn removeThreads(self: *@This(), num: usize) !void {
        while(true) {
            const old_val = @atomicLoad(usize, &self.running_threads, .Acquire);
            if(old_val < num) return error.NotEnoughThreadsToExit;
            if(@cmpxchgWeak(usize, &self.running_threads, old_val, old_val - num, .AcqRel, .Acquire)) |_| {
                return doRemoveThreads(num);
            }
        }
    }

    pub fn addThreads(self: *@This(), num: usize) !void {
        while(true) {
            @atomicRmw(usize, &self.running_threads, .Add, num, .AcqRel);
            return doAddThreads(num);
        }
    }

    pub fn setNumThreads(self: *@This(), num: usize) !void {
        const old_running_threads = @atomicRmw(usize, &self.running_threads, .Xchg, num, .AcqRel);
        if(old_running_threads < num) {
            return self.doAddThreads(num - old_running_threads);
        } else {
            return self.doRemoveThreads(old_running_threads - num);
        }
    }

    pub fn addWork(self: *@This(), work: Work) !void {
        self.queue.push(work);
    }

    fn killOneThread(self: *@This()) !void {
        self.queue.push(try allocWork(
            null,
            undefined,
            undefined,
        ));
    }

    fn doRemoveThreads(self: *@This(), num: usize) !void {
        var i: usize = 0;
        while(i < num) : (i += 1) {
            try self.killOneThread();
        }
    }

    fn threadWorker(self: *@This()) void {
        while(true) {
            const work = self.queue.pop();
            if(work.work) |f| {
                f(
                    work.callback_environ,
                    work.context,
                    work,
                );
            } else {
                work_alloc.allocator().destroy(work);
                return;
            }
        }
    }

    fn startOneThread(self: *@This()) !void {
        const t = try std.Thread.spawn(.{}, threadWorker, .{self});
        t.detach();
    }

    fn doAddThreads(self: *@This(), num: usize) !void {
        var i: usize = 0;
        while(i < num) : (i += 1) {
            try self.startOneThread();
        }
    }
};
