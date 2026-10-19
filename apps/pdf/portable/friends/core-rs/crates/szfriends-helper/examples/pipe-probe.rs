//! The Windows pipe test plan's tool (ADR 0015 § 8; `tests/vm/windows-pipe-plan.sh` runs it as the user and as
//! another account). It stages what an attacker could and reports what the client decided:
//!
//! - `sid`: this process's user SID;
//! - `name <state dir>`: a fresh pipe name of the advertised form, for this user and state directory;
//! - `squat <name> <sddl> <report>`: creates that pipe first (with `WRITE_OWNER`, so its owner can be changed),
//!   writes `<pid> <handle>` to the report, waits for one client and appends `bytes <n>`: what it was sent;
//! - `set-owner <pid> <handle> <sid>`: makes `sid` the owner of another process's pipe;
//! - `advertise <state dir> <name> <pid>`: points `helper.pipe` at a name and `helper.lock` at a process;
//! - `connect <state dir>`: the client's verdict: `connected`, `no-helper`, `refused <check>` or `error <text>`.

#[cfg(windows)]
fn main() {
    use std::io::Write;
    use std::time::Duration;

    use szfriends_contract::pipe::{advertised_name_path, lock_owner_line, lock_path, pipe_name};
    use szfriends_helper::client::{connect, ConnectError};
    use szfriends_helper::state::StateDir;
    use szfriends_helper::windows::ipc::own_token;
    use szfriends_helper_sys::pipe::PipeListener;
    use szfriends_helper_sys::testing::set_owner_of_remote_handle;

    const WRITE_OWNER: u32 = 0x0008_0000;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let arg = |i: usize| args.get(i).cloned().unwrap_or_else(|| panic!("missing argument {i}"));
    match arg(0).as_str() {
        "sid" => println!("{}", own_token().expect("token").user.as_str()),
        "name" => {
            let state = StateDir::new(arg(1).into());
            let mut nonce = [0u8; 16];
            szfriends_crypto::random_bytes(&mut nonce);
            println!("{}", pipe_name(&own_token().expect("token").user, &state.canonical, &nonce));
        }
        "squat" => {
            let listener = PipeListener::create_with(&arg(1), &arg(2), WRITE_OWNER, true).expect("pipe created");
            let report = arg(3);
            let handle = listener.pending_raw().expect("an instance");
            std::fs::write(&report, format!("{} {handle}\n", std::process::id())).unwrap();
            // Gives up after a minute, so a test that went wrong leaves nothing running.
            std::thread::spawn(|| {
                std::thread::sleep(Duration::from_secs(60));
                std::process::exit(2);
            });
            let stream = listener.accept().expect("accept").expect("a client");
            let mut total = 0;
            let mut buffer = [0u8; 1024];
            while let Ok(n) = stream.read(&mut buffer) {
                if n == 0 {
                    break;
                }
                total += n;
            }
            let mut file = std::fs::OpenOptions::new().append(true).open(&report).unwrap();
            writeln!(file, "bytes {total}").unwrap();
        }
        "set-owner" => {
            let (pid, handle) = (arg(1).parse().unwrap(), arg(2).parse().unwrap());
            set_owner_of_remote_handle(pid, handle, &arg(3)).expect("owner set");
            println!("owner set");
        }
        "advertise" => {
            let state = StateDir::new(arg(1).into());
            std::fs::create_dir_all(state.path.join("ipc")).unwrap();
            std::fs::write(advertised_name_path(&state.path), format!("{}\n", arg(2))).unwrap();
            std::fs::write(lock_path(&state.path), lock_owner_line(arg(3).parse().unwrap())).unwrap();
        }
        "connect" => match connect(&StateDir::new(arg(1).into())) {
            Ok(_) => println!("connected"),
            Err(ConnectError::NoHelper) => println!("no-helper"),
            Err(ConnectError::Refused(check)) => println!("refused {check}"),
            Err(ConnectError::Io(error)) => println!("error {error}"),
        },
        other => panic!("unknown command {other}"),
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("pipe-probe is a Windows tool");
}
