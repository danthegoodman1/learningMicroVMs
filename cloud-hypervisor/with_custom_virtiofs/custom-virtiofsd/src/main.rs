use std::ffi::CStr;
use std::fs::File;
use std::io;
use std::path::Path;
use std::process;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

use clap::Parser;
use log::{error, info};
use vhost::vhost_user::Error::Disconnected;
use vhost::vhost_user::Listener;
use vhost_user_backend::Error::HandleRequest;
use vhost_user_backend::VhostUserDaemon;
use virtiofsd::filesystem::{
    Context, Entry, Extensions, FileSystem, FsOptions, GetxattrReply, ListxattrReply, OpenOptions,
    SerializableFileSystem, SetattrValid, SetxattrFlags, ZeroCopyReader, ZeroCopyWriter,
};
use virtiofsd::fuse;
use virtiofsd::passthrough::{CachePolicy, Config, PassthroughFs};
use virtiofsd::vhost_user::VhostUserFsBackendBuilder;
use vm_memory::{GuestMemoryAtomic, GuestMemoryMmap};

#[derive(Debug, Parser)]
#[command(
    name = "custom-virtiofsd",
    about = "Minimal custom virtio-fs daemon that logs and proxies to a host directory"
)]
struct Opt {
    #[arg(long, default_value = "/tmp/cloud-hypervisor-custom-virtiofs.sock")]
    socket_path: String,

    #[arg(long)]
    shared_dir: String,

    #[arg(long, default_value = "hostshare")]
    tag: String,

    #[arg(long, default_value_t = 0)]
    thread_pool_size: usize,
}

struct LoggingPassthroughFs {
    inner: PassthroughFs,
}

impl LoggingPassthroughFs {
    fn new(shared_dir: String) -> io::Result<Self> {
        let fs = PassthroughFs::new(Config {
            root_dir: shared_dir,
            cache_policy: CachePolicy::Never,
            entry_timeout: Duration::from_secs(0),
            attr_timeout: Duration::from_secs(0),
            writeback: false,
            xattr: false,
            readdirplus: false,
            ..Default::default()
        })?;

        Ok(Self { inner: fs })
    }

    fn log_name(op: &str, name: &CStr) {
        info!("customfs {op} name={}", name.to_string_lossy());
    }

    fn log_inode<I: Into<u64>>(op: &str, inode: I) {
        info!("customfs {op} inode={}", inode.into());
    }
}

impl FileSystem for LoggingPassthroughFs {
    type Inode = <PassthroughFs as FileSystem>::Inode;
    type Handle = <PassthroughFs as FileSystem>::Handle;
    type DirIter = <PassthroughFs as FileSystem>::DirIter;

    fn init(&self, capable: FsOptions) -> io::Result<FsOptions> {
        info!("customfs init");
        self.inner.init(capable)
    }

    fn destroy(&self) {
        info!("customfs destroy");
        self.inner.destroy()
    }

    fn lookup(&self, ctx: Context, parent: Self::Inode, name: &CStr) -> io::Result<Entry> {
        Self::log_name("lookup", name);
        self.inner.lookup(ctx, parent, name)
    }

    fn forget(&self, ctx: Context, inode: Self::Inode, count: u64) {
        self.inner.forget(ctx, inode, count)
    }

    fn batch_forget(&self, ctx: Context, requests: Vec<(Self::Inode, u64)>) {
        self.inner.batch_forget(ctx, requests)
    }

    fn getattr(
        &self,
        ctx: Context,
        inode: Self::Inode,
        handle: Option<Self::Handle>,
    ) -> io::Result<(fuse::Attr, Duration)> {
        self.inner.getattr(ctx, inode, handle)
    }

    fn setattr(
        &self,
        ctx: Context,
        inode: Self::Inode,
        attr: fuse::SetattrIn,
        handle: Option<Self::Handle>,
        valid: SetattrValid,
    ) -> io::Result<(fuse::Attr, Duration)> {
        self.inner.setattr(ctx, inode, attr, handle, valid)
    }

    fn readlink(&self, ctx: Context, inode: Self::Inode) -> io::Result<Vec<u8>> {
        self.inner.readlink(ctx, inode)
    }

    fn symlink(
        &self,
        ctx: Context,
        linkname: &CStr,
        parent: Self::Inode,
        name: &CStr,
        extensions: Extensions,
    ) -> io::Result<Entry> {
        self.inner.symlink(ctx, linkname, parent, name, extensions)
    }

    #[allow(clippy::too_many_arguments)]
    fn mknod(
        &self,
        ctx: Context,
        inode: Self::Inode,
        name: &CStr,
        mode: u32,
        rdev: u32,
        umask: u32,
        extensions: Extensions,
    ) -> io::Result<Entry> {
        self.inner
            .mknod(ctx, inode, name, mode, rdev, umask, extensions)
    }

    fn mkdir(
        &self,
        ctx: Context,
        parent: Self::Inode,
        name: &CStr,
        mode: u32,
        umask: u32,
        extensions: Extensions,
    ) -> io::Result<Entry> {
        self.inner.mkdir(ctx, parent, name, mode, umask, extensions)
    }

    fn unlink(&self, ctx: Context, parent: Self::Inode, name: &CStr) -> io::Result<()> {
        Self::log_name("unlink", name);
        self.inner.unlink(ctx, parent, name)
    }

    fn rmdir(&self, ctx: Context, parent: Self::Inode, name: &CStr) -> io::Result<()> {
        self.inner.rmdir(ctx, parent, name)
    }

    fn rename(
        &self,
        ctx: Context,
        olddir: Self::Inode,
        oldname: &CStr,
        newdir: Self::Inode,
        newname: &CStr,
        flags: u32,
    ) -> io::Result<()> {
        info!(
            "customfs rename old={} new={}",
            oldname.to_string_lossy(),
            newname.to_string_lossy()
        );
        self.inner
            .rename(ctx, olddir, oldname, newdir, newname, flags)
    }

    fn link(
        &self,
        ctx: Context,
        inode: Self::Inode,
        newparent: Self::Inode,
        newname: &CStr,
    ) -> io::Result<Entry> {
        self.inner.link(ctx, inode, newparent, newname)
    }

    fn open(
        &self,
        ctx: Context,
        inode: Self::Inode,
        kill_priv: bool,
        flags: u32,
    ) -> io::Result<(Option<Self::Handle>, OpenOptions)> {
        Self::log_inode("open", inode);
        self.inner.open(ctx, inode, kill_priv, flags)
    }

    #[allow(clippy::too_many_arguments)]
    fn create(
        &self,
        ctx: Context,
        parent: Self::Inode,
        name: &CStr,
        mode: u32,
        kill_priv: bool,
        flags: u32,
        umask: u32,
        extensions: Extensions,
    ) -> io::Result<(Entry, Option<Self::Handle>, OpenOptions)> {
        Self::log_name("create", name);
        self.inner
            .create(ctx, parent, name, mode, kill_priv, flags, umask, extensions)
    }

    #[allow(clippy::too_many_arguments)]
    fn read<W: ZeroCopyWriter>(
        &self,
        ctx: Context,
        inode: Self::Inode,
        handle: Self::Handle,
        w: W,
        size: u32,
        offset: u64,
        lock_owner: Option<u64>,
        flags: u32,
    ) -> io::Result<usize> {
        Self::log_inode("read", inode);
        self.inner
            .read(ctx, inode, handle, w, size, offset, lock_owner, flags)
    }

    #[allow(clippy::too_many_arguments)]
    fn write<R: ZeroCopyReader>(
        &self,
        ctx: Context,
        inode: Self::Inode,
        handle: Self::Handle,
        r: R,
        size: u32,
        offset: u64,
        lock_owner: Option<u64>,
        delayed_write: bool,
        kill_priv: bool,
        flags: u32,
    ) -> io::Result<usize> {
        Self::log_inode("write", inode);
        self.inner.write(
            ctx,
            inode,
            handle,
            r,
            size,
            offset,
            lock_owner,
            delayed_write,
            kill_priv,
            flags,
        )
    }

    fn flush(
        &self,
        ctx: Context,
        inode: Self::Inode,
        handle: Self::Handle,
        lock_owner: u64,
    ) -> io::Result<()> {
        self.inner.flush(ctx, inode, handle, lock_owner)
    }

    fn fsync(
        &self,
        ctx: Context,
        inode: Self::Inode,
        datasync: bool,
        handle: Self::Handle,
    ) -> io::Result<()> {
        self.inner.fsync(ctx, inode, datasync, handle)
    }

    fn fallocate(
        &self,
        ctx: Context,
        inode: Self::Inode,
        handle: Self::Handle,
        mode: u32,
        offset: u64,
        length: u64,
    ) -> io::Result<()> {
        self.inner
            .fallocate(ctx, inode, handle, mode, offset, length)
    }

    #[allow(clippy::too_many_arguments)]
    fn release(
        &self,
        ctx: Context,
        inode: Self::Inode,
        flags: u32,
        handle: Self::Handle,
        flush: bool,
        flock_release: bool,
        lock_owner: Option<u64>,
    ) -> io::Result<()> {
        Self::log_inode("release", inode);
        self.inner
            .release(ctx, inode, flags, handle, flush, flock_release, lock_owner)
    }

    fn statfs(&self, ctx: Context, inode: Self::Inode) -> io::Result<libc::statvfs64> {
        self.inner.statfs(ctx, inode)
    }

    fn setxattr(
        &self,
        ctx: Context,
        inode: Self::Inode,
        name: &CStr,
        value: &[u8],
        flags: u32,
        extra_flags: SetxattrFlags,
    ) -> io::Result<()> {
        self.inner
            .setxattr(ctx, inode, name, value, flags, extra_flags)
    }

    fn getxattr(
        &self,
        ctx: Context,
        inode: Self::Inode,
        name: &CStr,
        size: u32,
    ) -> io::Result<GetxattrReply> {
        self.inner.getxattr(ctx, inode, name, size)
    }

    fn listxattr(&self, ctx: Context, inode: Self::Inode, size: u32) -> io::Result<ListxattrReply> {
        self.inner.listxattr(ctx, inode, size)
    }

    fn removexattr(&self, ctx: Context, inode: Self::Inode, name: &CStr) -> io::Result<()> {
        self.inner.removexattr(ctx, inode, name)
    }

    fn opendir(
        &self,
        ctx: Context,
        inode: Self::Inode,
        flags: u32,
    ) -> io::Result<(Option<Self::Handle>, OpenOptions)> {
        self.inner.opendir(ctx, inode, flags)
    }

    fn readdir(
        &self,
        ctx: Context,
        inode: Self::Inode,
        handle: Self::Handle,
        size: u32,
        offset: u64,
    ) -> io::Result<Self::DirIter> {
        Self::log_inode("readdir", inode);
        self.inner.readdir(ctx, inode, handle, size, offset)
    }

    fn fsyncdir(
        &self,
        ctx: Context,
        inode: Self::Inode,
        datasync: bool,
        handle: Self::Handle,
    ) -> io::Result<()> {
        self.inner.fsyncdir(ctx, inode, datasync, handle)
    }

    fn releasedir(
        &self,
        ctx: Context,
        inode: Self::Inode,
        flags: u32,
        handle: Self::Handle,
    ) -> io::Result<()> {
        self.inner.releasedir(ctx, inode, flags, handle)
    }

    fn access(&self, ctx: Context, inode: Self::Inode, mask: u32) -> io::Result<()> {
        self.inner.access(ctx, inode, mask)
    }

    fn lseek(
        &self,
        ctx: Context,
        inode: Self::Inode,
        handle: Self::Handle,
        offset: u64,
        whence: u32,
    ) -> io::Result<u64> {
        self.inner.lseek(ctx, inode, handle, offset, whence)
    }

    #[allow(clippy::too_many_arguments)]
    fn copyfilerange(
        &self,
        ctx: Context,
        inode_in: Self::Inode,
        handle_in: Self::Handle,
        offset_in: u64,
        inode_out: Self::Inode,
        handle_out: Self::Handle,
        offset_out: u64,
        len: u64,
        flags: u64,
    ) -> io::Result<usize> {
        self.inner.copyfilerange(
            ctx, inode_in, handle_in, offset_in, inode_out, handle_out, offset_out, len, flags,
        )
    }

    fn syncfs(&self, ctx: Context, inode: Self::Inode) -> io::Result<()> {
        self.inner.syncfs(ctx, inode)
    }
}

impl SerializableFileSystem for LoggingPassthroughFs {
    fn prepare_serialization(&self, cancel: Arc<AtomicBool>) {
        self.inner.prepare_serialization(cancel)
    }

    fn serialize(&self, state_pipe: File) -> io::Result<()> {
        self.inner.serialize(state_pipe)
    }

    fn deserialize_and_apply(&self, state_pipe: File) -> io::Result<()> {
        self.inner.deserialize_and_apply(state_pipe)
    }
}

fn run(fs: LoggingPassthroughFs, opt: &Opt) -> io::Result<()> {
    let _ = std::fs::remove_file(&opt.socket_path);
    let listener = Listener::new(&opt.socket_path, true)
        .map_err(|err| io::Error::new(io::ErrorKind::Other, format!("{err}")))?;

    let backend = Arc::new(
        VhostUserFsBackendBuilder::default()
            .set_thread_pool_size(opt.thread_pool_size)
            .set_tag(Some(opt.tag.clone()))
            .build(fs)
            .map_err(|err| io::Error::new(io::ErrorKind::Other, format!("{err}")))?,
    );

    let mut daemon = VhostUserDaemon::new(
        String::from("custom-virtiofsd-backend"),
        backend,
        GuestMemoryAtomic::new(GuestMemoryMmap::new()),
    )
    .map_err(|err| io::Error::new(io::ErrorKind::Other, format!("{err}")))?;

    info!("customfs waiting for vhost-user socket connection");
    daemon
        .start(listener)
        .map_err(|err| io::Error::new(io::ErrorKind::Other, format!("{err:?}")))?;

    info!("customfs client connected");
    match daemon.wait() {
        Ok(()) => Ok(()),
        Err(HandleRequest(Disconnected)) => {
            info!("customfs client disconnected");
            Ok(())
        }
        Err(err) => Err(io::Error::new(io::ErrorKind::Other, format!("{err:?}"))),
    }
}

fn main() {
    env_logger::init();
    let opt = Opt::parse();

    if !Path::new(&opt.shared_dir).is_dir() {
        error!(
            "--shared-dir must be an existing directory: {}",
            opt.shared_dir
        );
        process::exit(1);
    }

    let fs = LoggingPassthroughFs::new(opt.shared_dir.clone()).unwrap_or_else(|err| {
        error!("failed to create passthrough filesystem: {err}");
        process::exit(1);
    });

    if let Err(err) = run(fs, &opt) {
        error!("custom virtio-fs daemon failed: {err}");
        process::exit(1);
    }
}
