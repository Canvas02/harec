// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

export @symbol("write") fn write(fd: int, buf: *const opaque, count: size) size;

export @symbol("close") fn close(fd: int) int;

export @symbol("dup2") fn dup2(old: int, new: int) int;

export @symbol("getpid") fn getpid() int;

export def EXIT_SUCCESS: int = 0;

export @symbol("exit") fn exit(status: int) never;

export @symbol("fork") fn fork() int;

export @symbol("execve") fn execve(path: *const u8, argv: *[*]nullable *const u8,
		envp: *[*]nullable *const u8) int;

export type time_t = i64;
export type suseconds_t = i32;

export type timeval = struct {
	tv_sec: time_t,
	tv_usec: suseconds_t,
	_pad: i32,
};

export type rusage = struct {
	ru_utime: timeval,
	ru_stime: timeval,
	ru_maxrss: i64,
	ru_ixrss: i64,
	ru_idrss: i64,
	ru_isrss: i64,
	ru_minflt: i64,
	ru_majflt: i64,
	ru_nswap: i64,
	ru_inblock: i64,
	ru_oublock: i64,
	ru_msgsnd: i64,
	ru_msgrcv: i64,
	ru_nsignals: i64,
	ru_nvcsw: i64,
	ru_nivcsw: i64,
};

export @symbol("wait4") fn wait4(
	wpid: int,
	status: *int,
	options: int,
	rusage: nullable *rusage
) int;

export fn wifexited(status: int) bool = wtermsig(status) == 0;
export fn wexitstatus(status: int) int = (status >> 8) & 0xff;

export fn wtermsig(status: int) int = status & 0o177;
export fn wifsignaled(status: int) bool =
	wtermsig(status) != 0o177 && wtermsig(status) != 0;

export @symbol("kill") fn kill(pid: int, signal: int) int;

@symbol("pipe") fn c_pipe(pipefd: *[2]int) int;
@symbol("fcntl") fn c_fcntl(fd: int, cmd: int, arg: int) int;
def F_SETFD: int = 2;
def FD_CLOEXEC: int = 1;
export def O_CLOEXEC: int = 0x1000000;

export fn pipe2(pipefd: *[2]int, flags: int) int = {
	let r = c_pipe(pipefd);
	if (r != 0) {
		return r;
	};
	if ((flags & O_CLOEXEC) != 0) {
		c_fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
		c_fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
	};
	return 0;
};

export def MAP_SHARED: uint = 0x0001;
export def MAP_PRIVATE: uint = 0x0002;
export def MAP_FIXED: uint = 0x0010;
export def MAP_ANON: uint = 0x1000;
export def MAP_ANONYMOUS: uint = MAP_ANON;

export def PROT_NONE: uint = 0x00;
export def PROT_READ: uint = 0x01;
export def PROT_WRITE: uint = 0x02;
export def PROT_EXEC: uint = 0x04;

export @symbol("mmap") fn mmap(
	addr: nullable *opaque,
	length: size,
	prot: int,
	flags: int,
	fd: int,
	offs: i64
) *opaque;

export @symbol("munmap") fn munmap(addr: *opaque, length: size) int;

export def SIGABRT: int = 6;
export def SIGCHLD: int = 20;
