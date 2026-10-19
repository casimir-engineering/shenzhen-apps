//! The helper's named pipe and a client's connection to it (ADR 0015 § 8).
//!
//! Every handle is overlapped, so one thread can read while another writes and a third cancels: a synchronous pipe
//! handle serialises its I/O, which would leave a goodbye stuck behind a read that never ends. Each operation waits
//! for its own completion or for the stream's close event, whichever comes first.

use std::io;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{
    ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_NO_DATA, ERROR_OPERATION_ABORTED, ERROR_PIPE_BUSY, ERROR_PIPE_CONNECTED,
    ERROR_PIPE_NOT_CONNECTED, GENERIC_READ, GENERIC_WRITE, HANDLE, PSID, WAIT_OBJECT_0,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SE_KERNEL_OBJECT,
};
use windows_sys::Win32::Security::{OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, ReadFile, WriteFile, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, OPEN_EXISTING,
    PIPE_ACCESS_DUPLEX, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, GetNamedPipeClientProcessId, GetNamedPipeServerProcessId, WaitNamedPipeW,
    PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
};
use windows_sys::Win32::System::Threading::{CreateEventW, SetEvent, WaitForMultipleObjects, WaitForSingleObject};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};

use super::{sid_string, wide, Handle, LocalMemory};

const BUFFER: u32 = 64 * 1024;
const INFINITE: u32 = u32::MAX;

fn event() -> io::Result<Handle> {
    // SAFETY: an unnamed manual-reset event, initially unset, with default security.
    Handle::new(unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) }).ok_or_else(io::Error::last_os_error)
}

fn is_set(event: &Handle) -> bool {
    // SAFETY: a zero timeout only polls the event's state.
    unsafe { WaitForSingleObject(event.raw(), 0) == WAIT_OBJECT_0 }
}

fn set(event: &Handle) {
    // SAFETY: `event` is a live event handle.
    unsafe { SetEvent(event.raw()) };
}

/// The listening side: the pipe's instances, created with one security descriptor, and a stop switch.
#[derive(Debug)]
pub struct PipeListener {
    name: Vec<u16>,
    descriptor: SecurityDescriptor,
    open_mode: u32,
    /// The instance waiting for the next client. There is always one while the listener runs, created before the
    /// previous one is handed out, so the name never lapses and no one else can create it in between.
    pending: Mutex<Option<Handle>>,
    stop: Handle,
}

#[derive(Debug)]
struct SecurityDescriptor(LocalMemory);

// SAFETY: the descriptor is written once by ConvertStringSecurityDescriptorToSecurityDescriptorW and afterwards only
// read by CreateNamedPipeW, from whichever thread; Windows does not tie it to a thread.
unsafe impl Send for SecurityDescriptor {}
// SAFETY: as above, shared reads only.
unsafe impl Sync for SecurityDescriptor {}

impl SecurityDescriptor {
    fn from_sddl(sddl: &str) -> io::Result<Self> {
        let text = wide(sddl);
        let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        // SAFETY: `text` is NUL-terminated; on success `descriptor` receives LocalAlloc'd memory we free on drop.
        let ok = unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                text.as_ptr(),
                1,
                &mut descriptor,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(LocalMemory(descriptor)))
    }
}

impl PipeListener {
    /// Creates the first instance of `name`, protected by `sddl` (an owner and a DACL), rejecting remote clients.
    /// Fails when the name already exists: someone else's pipe, which this helper must never join.
    pub fn create(name: &str, sddl: &str) -> io::Result<Self> {
        Self::create_with(name, sddl, 0, true)
    }

    /// [`Self::create`] with more open-mode flags (`WRITE_OWNER` for a test) and the first-instance check optional.
    pub fn create_with(name: &str, sddl: &str, extra_open_mode: u32, first: bool) -> io::Result<Self> {
        let listener = Self {
            name: wide(name),
            descriptor: SecurityDescriptor::from_sddl(sddl)?,
            open_mode: PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | extra_open_mode,
            pending: Mutex::new(None),
            stop: event()?,
        };
        let instance = listener.instance(first)?;
        *listener.pending.lock().unwrap_or_else(|e| e.into_inner()) = Some(instance);
        Ok(listener)
    }

    fn instance(&self, first: bool) -> io::Result<Handle> {
        let attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.descriptor.0 .0,
            bInheritHandle: 0,
        };
        let open_mode = self.open_mode | if first { FILE_FLAG_FIRST_PIPE_INSTANCE } else { 0 };
        let pipe_mode = PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS;
        // SAFETY: the name is NUL-terminated and the attributes point at a live descriptor for the call.
        let raw = unsafe {
            CreateNamedPipeW(
                self.name.as_ptr(),
                open_mode,
                pipe_mode,
                PIPE_UNLIMITED_INSTANCES,
                BUFFER,
                BUFFER,
                0,
                &attributes,
            )
        };
        Handle::new(raw).ok_or_else(io::Error::last_os_error)
    }

    /// Waits for the next client; `Ok(None)` once [`Self::stop`] was called.
    pub fn accept(&self) -> io::Result<Option<PipeStream>> {
        loop {
            if is_set(&self.stop) {
                return Ok(None);
            }
            let taken = self.pending.lock().unwrap_or_else(|e| e.into_inner()).take();
            let instance = match taken {
                Some(instance) => instance,
                None => self.instance(false)?,
            };
            let connected = self.wait_for_client(&instance)?;
            // The next instance exists before this one is handed out.
            let next = self.instance(false);
            if let Ok(next) = next {
                *self.pending.lock().unwrap_or_else(|e| e.into_inner()) = Some(next);
            }
            match connected {
                Connection::Connected => return Ok(Some(PipeStream::new(instance)?)),
                Connection::Stopped => return Ok(None),
                Connection::Gone => continue,
            }
        }
    }

    fn wait_for_client(&self, instance: &Handle) -> io::Result<Connection> {
        let done = event()?;
        // SAFETY: an all-zero OVERLAPPED with our event; it stays on this stack frame until the operation is over
        // (completed, or cancelled and waited for below).
        let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
        overlapped.hEvent = done.raw();
        // SAFETY: a live pipe instance and the OVERLAPPED above. In overlapped mode the call returns 0.
        unsafe { ConnectNamedPipe(instance.raw(), &mut overlapped) };
        let error = io::Error::last_os_error();
        match error.raw_os_error().map(|e| e as u32) {
            Some(ERROR_PIPE_CONNECTED) => return Ok(Connection::Connected),
            Some(ERROR_NO_DATA) => return Ok(Connection::Gone),
            Some(ERROR_IO_PENDING) => {}
            _ => return Err(error),
        }
        let handles = [done.raw(), self.stop.raw()];
        // SAFETY: two live event handles.
        let woke = unsafe { WaitForMultipleObjects(2, handles.as_ptr(), 0, INFINITE) };
        if woke != WAIT_OBJECT_0 {
            // SAFETY: cancels this one operation, then waits for it to finish so `overlapped` may go.
            unsafe {
                CancelIoEx(instance.raw(), &overlapped);
                let mut ignored = 0;
                GetOverlappedResult(instance.raw(), &overlapped, &mut ignored, 1);
            }
            return Ok(Connection::Stopped);
        }
        let mut ignored = 0;
        // SAFETY: the operation completed; this reads its result.
        if unsafe { GetOverlappedResult(instance.raw(), &overlapped, &mut ignored, 0) } == 0 {
            return Ok(Connection::Gone);
        }
        Ok(Connection::Connected)
    }

    /// Stops [`Self::accept`], now or at its next call, and closes the waiting instance.
    pub fn stop(&self) {
        set(&self.stop);
        self.pending.lock().unwrap_or_else(|e| e.into_inner()).take();
    }

    /// The waiting instance's raw handle value, for a test that hands it to another process.
    #[cfg(feature = "testing")]
    pub fn pending_raw(&self) -> Option<HANDLE> {
        self.pending.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(Handle::raw)
    }
}

enum Connection {
    Connected,
    /// The client came and went before we saw it.
    Gone,
    Stopped,
}

/// One end of a connected pipe. Reads and writes take `&self`, so a reader thread and a writer can share it.
/// [`PipeStream::close`] wakes every operation in progress and closes the handle once the last one has finished, so
/// the other end sees the connection end (after reading what was already written).
#[derive(Debug)]
pub struct PipeStream {
    handle: Mutex<InUse>,
    closed: Handle,
}

#[derive(Debug)]
struct InUse {
    handle: Option<Handle>,
    /// Operations using the raw handle now; it is closed only when none is.
    operations: usize,
}

/// One use of the raw handle; ends with [`PipeStream::release`].
struct Use(HANDLE);

impl PipeStream {
    fn new(handle: Handle) -> io::Result<Self> {
        Ok(Self { handle: Mutex::new(InUse { handle: Some(handle), operations: 0 }), closed: event()? })
    }

    fn acquire(&self) -> io::Result<Use> {
        let mut state = self.handle.lock().unwrap_or_else(|e| e.into_inner());
        match &state.handle {
            Some(handle) if !is_set(&self.closed) => {
                let raw = handle.raw();
                state.operations += 1;
                Ok(Use(raw))
            }
            _ => Err(io::Error::from(io::ErrorKind::NotConnected)),
        }
    }

    fn release(&self, _: Use) {
        let mut state = self.handle.lock().unwrap_or_else(|e| e.into_inner());
        state.operations -= 1;
        if state.operations == 0 && is_set(&self.closed) {
            state.handle = None;
        }
    }

    /// Runs `f` with the raw handle while it is open; `None` once closed.
    fn with_handle<T>(&self, f: impl FnOnce(HANDLE) -> T) -> Option<T> {
        let using = self.acquire().ok()?;
        let result = f(using.0);
        self.release(using);
        Some(result)
    }

    /// Opens `name` as a client, waiting up to `timeout` while every instance is busy. The server may only
    /// identify this client, never act as it (`SECURITY_IDENTIFICATION`).
    pub fn connect(name: &str, timeout: Duration) -> io::Result<Self> {
        let text = wide(name);
        let deadline = Instant::now() + timeout;
        let flags = FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION;
        loop {
            // SAFETY: a NUL-terminated name, no sharing, no security attributes, no template.
            let raw = unsafe {
                CreateFileW(text.as_ptr(), GENERIC_READ | GENERIC_WRITE, 0, std::ptr::null(), OPEN_EXISTING, flags, 0)
            };
            if let Some(handle) = Handle::new(raw) {
                return Self::new(handle);
            }
            let error = io::Error::last_os_error();
            let left = deadline.saturating_duration_since(Instant::now());
            if error.raw_os_error() != Some(ERROR_PIPE_BUSY as i32) || left.is_zero() {
                return Err(error);
            }
            // SAFETY: a NUL-terminated name; waits at most `left`.
            unsafe { WaitNamedPipeW(text.as_ptr(), left.as_millis().clamp(1, u128::from(u32::MAX - 1)) as u32) };
        }
    }

    /// Reads what has arrived; `Ok(0)` at the end, including after [`Self::close`].
    pub fn read(&self, buffer: &mut [u8]) -> io::Result<usize> {
        let length = buffer.len().min(u32::MAX as usize) as u32;
        let pointer = buffer.as_mut_ptr();
        // SAFETY: `buffer` stays borrowed until `io` returns, which is after the operation has finished.
        let read = self
            .io(|handle, overlapped| unsafe { ReadFile(handle, pointer, length, std::ptr::null_mut(), overlapped) });
        match read {
            Ok(read) => Ok(read as usize),
            Err(e) if is_closed(&e) => Ok(0),
            Err(e) => Err(e),
        }
    }

    /// Writes some of `buffer`.
    pub fn write(&self, buffer: &[u8]) -> io::Result<usize> {
        let length = buffer.len().min(u32::MAX as usize) as u32;
        let pointer = buffer.as_ptr();
        // SAFETY: as for `read`.
        let written = self
            .io(|handle, overlapped| unsafe { WriteFile(handle, pointer, length, std::ptr::null_mut(), overlapped) });
        match written {
            Ok(written) => Ok(written as usize),
            Err(e) if is_closed(&e) => Err(io::Error::from(io::ErrorKind::BrokenPipe)),
            Err(e) => Err(e),
        }
    }

    pub fn write_all(&self, mut buffer: &[u8]) -> io::Result<()> {
        while !buffer.is_empty() {
            match self.write(buffer)? {
                0 => return Err(io::Error::from(io::ErrorKind::WriteZero)),
                written => buffer = &buffer[written..],
            }
        }
        Ok(())
    }

    /// Ends every read and write on this stream, now and later, on any thread, and closes the handle as soon as no
    /// operation uses it.
    pub fn close(&self) {
        set(&self.closed);
        let mut state = self.handle.lock().unwrap_or_else(|e| e.into_inner());
        if state.operations == 0 {
            state.handle = None;
        }
    }

    fn io(&self, start: impl FnOnce(HANDLE, *mut OVERLAPPED) -> i32) -> io::Result<u32> {
        let using = self.acquire()?;
        let result = self.io_with(using.0, start);
        self.release(using);
        result
    }

    fn io_with(&self, handle: HANDLE, start: impl FnOnce(HANDLE, *mut OVERLAPPED) -> i32) -> io::Result<u32> {
        let done = event()?;
        // SAFETY: zeroed with our event; it lives on this frame until GetOverlappedResult(wait) below returns.
        let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
        overlapped.hEvent = done.raw();
        if start(handle, &mut overlapped) == 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(ERROR_IO_PENDING as i32) {
                return Err(error);
            }
            let handles = [done.raw(), self.closed.raw()];
            // SAFETY: two live events.
            if unsafe { WaitForMultipleObjects(2, handles.as_ptr(), 0, INFINITE) } != WAIT_OBJECT_0 {
                // SAFETY: cancels this one operation; the wait below lets it finish before `overlapped` goes.
                unsafe { CancelIoEx(handle, &overlapped) };
            }
        }
        let mut transferred = 0;
        // SAFETY: waits for the operation to be over, completed or cancelled; the handle stays open meanwhile.
        if unsafe { GetOverlappedResult(handle, &overlapped, &mut transferred, 1) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(transferred)
    }

    /// The process at the server end (`GetNamedPipeServerProcessId`).
    pub fn server_process_id(&self) -> Option<u32> {
        let mut pid = 0;
        // SAFETY: a live pipe handle and an out parameter.
        let ok = self.with_handle(|handle| unsafe { GetNamedPipeServerProcessId(handle, &mut pid) })?;
        (ok != 0).then_some(pid)
    }

    /// The process at the client end (`GetNamedPipeClientProcessId`).
    pub fn client_process_id(&self) -> Option<u32> {
        let mut pid = 0;
        // SAFETY: as above.
        let ok = self.with_handle(|handle| unsafe { GetNamedPipeClientProcessId(handle, &mut pid) })?;
        (ok != 0).then_some(pid)
    }

    /// The pipe object's owner SID, in string form.
    pub fn owner(&self) -> Option<String> {
        self.with_handle(|handle| {
            let mut owner: PSID = std::ptr::null_mut();
            let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
            // SAFETY: asks for the owner only; `owner` points into `descriptor`, which we free after converting.
            let status = unsafe {
                GetSecurityInfo(
                    handle,
                    SE_KERNEL_OBJECT,
                    OWNER_SECURITY_INFORMATION,
                    &mut owner,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut descriptor,
                )
            };
            let _descriptor = LocalMemory(descriptor);
            if status != 0 || owner.is_null() {
                return None;
            }
            // SAFETY: `owner` is a SID inside the live descriptor.
            unsafe { sid_string(owner) }
        })?
    }

    /// The raw handle value, for a test that hands it to another process.
    #[cfg(feature = "testing")]
    pub fn raw(&self) -> Option<HANDLE> {
        self.with_handle(|handle| handle)
    }
}

fn is_closed(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::NotConnected
        || matches!(
            error.raw_os_error().map(|e| e as u32),
            Some(ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED | ERROR_OPERATION_ABORTED | ERROR_NO_DATA)
        )
}
