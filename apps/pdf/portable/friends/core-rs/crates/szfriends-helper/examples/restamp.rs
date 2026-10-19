//! For installer and handover tests: `restamp <helper> <output> <build>` writes a copy of a helper binary whose
//! stamp names another build, so a test can run an older (or newer) helper next to the one it built.

fn main() -> std::process::ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let [input, output, build] = arguments.as_slice() else {
        eprintln!("usage: restamp <helper> <output> <build>");
        return std::process::ExitCode::from(64);
    };
    let Ok(build) = build.parse::<u64>() else {
        eprintln!("restamp: the build is a number");
        return std::process::ExitCode::from(64);
    };
    let mut bytes = match std::fs::read(input) {
        Ok(bytes) => bytes,
        Err(error) => {
            eprintln!("restamp: {input}: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    if szfriends_helper::stamp::restamp(&mut bytes, build) == 0 {
        eprintln!("restamp: {input} carries no stamp");
        return std::process::ExitCode::FAILURE;
    }
    match std::fs::write(output, bytes) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("restamp: {output}: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}
