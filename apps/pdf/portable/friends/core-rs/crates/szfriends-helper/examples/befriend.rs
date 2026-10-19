//! For end-to-end tests: `befriend <home a> <home b> <name a> <name b>` makes two test Friends homes friends of each
//! other, each with a key store of its own under its home, and prints each home's conversation id.

fn main() -> std::process::ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let [a, b, name_a, name_b] = arguments.as_slice() else {
        eprintln!("usage: befriend <home a> <home b> <name a> <name b>");
        return std::process::ExitCode::from(64);
    };
    match szfriends_helper::service::seed::befriend(a.as_ref(), b.as_ref(), (name_a, name_b)) {
        Ok((in_a, in_b)) => {
            println!("{in_a} {in_b}");
            std::process::ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("befriend: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}
