use anyhow::{bail, Result};
use seahelmd::client;
use seahelmd::proto::Msg;

const USAGE: &str = "usage: seahelmd <run|attach> <name> [cmd...] | new [--hold SECS] <name> [--] cmd... | list | send <name> <text> | history <name> | snapshot <name> | kill <name> | version";

fn main() {
    if let Err(e) = run() {
        eprintln!("seahelmd: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (verb, rest) = args.split_first().map(|(v, r)| (v.as_str(), r)).unwrap_or(("", &[]));
    match verb {
        "version" => println!("seahelmd {}", env!("CARGO_PKG_VERSION")),
        "__serve" => {
            let (hold, rest) = take_hold(rest)?;
            let (name, rest) = rest.split_first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
            let argv = rest.strip_prefix(&["--".to_string()][..]).unwrap_or(rest);
            seahelmd::daemon::serve(&client::socket_path(name)?, name, argv, hold)?;
        }
        "run" => {
            // The session is the user's shell, and the command is
            // typed into it — so the session outlives the command, and running
            // on a live session is the same act as on a new one.
            let (name, cmd) = rest.split_first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
            client::ensure(name, &[])?;
            if !cmd.is_empty() {
                let mut line = cmd.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" ").into_bytes();
                // CR, not LF: at the prompt the line editor has the PTY raw,
                // and accept-line is bound to CR.
                line.push(b'\r');
                client::request(name, &Msg::Send(line))?;
            }
        }
        "new" => {
            // A session whose program is `cmd` itself, not a shell it is typed
            // into: it ends when the program does. `--hold SECS` starts it
            // only once a client attaches, or when the hold runs out.
            let (hold, rest) = take_hold(rest)?;
            let (name, cmd) = rest.split_first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
            let cmd = cmd.strip_prefix(&["--".to_string()][..]).unwrap_or(cmd);
            if !client::ensure_held(name, cmd, hold)? {
                bail!("session {name} already exists");
            }
        }
        "attach" => {
            let (name, cmd) = rest.split_first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
            client::ensure(name, cmd)?;
            client::attach(name)?;
        }
        "list" | "ls" => {
            let dir = client::socket_dir();
            let Ok(entries) = std::fs::read_dir(&dir) else { return Ok(()) };
            let mut names: Vec<String> = entries
                .flatten()
                .filter(|e| e.file_type().map(|t| !t.is_file() && !t.is_dir()).unwrap_or(false))
                .filter_map(|e| e.file_name().into_string().ok())
                .collect();
            names.sort();
            for name in names {
                match client::request(&name, &Msg::Info) {
                    Ok(Msg::Text(line)) => println!("{line}"),
                    // Nobody listening: a daemon that died without cleaning up.
                    Err(e) if client::is_gone(&e) => {
                        let _ = std::fs::remove_file(dir.join(&name));
                    }
                    // Listening but not answering is a busy or wedged daemon.
                    // Its socket stays — removing it would orphan a session
                    // that may yet come back — and the row says so.
                    _ => println!("name={name}\tstatus=unreachable"),
                }
            }
        }
        "send" => {
            let (name, text) = rest.split_first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
            client::request(name, &Msg::Send(text.join(" ").into_bytes()))?;
        }
        "history" => {
            let name = rest.first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
            if let Msg::Text(text) = client::request(name, &Msg::History)? {
                print!("{text}");
            }
        }
        "snapshot" => {
            let name = rest.first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
            if let Msg::Text(json) = client::request(name, &Msg::Snapshot)? {
                println!("{json}");
            }
        }
        "kill" => {
            let name = rest.first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
            client::request(name, &Msg::Kill)?;
        }
        _ => bail!(USAGE),
    }
    Ok(())
}

/// A leading `--hold SECS`, if there is one.
fn take_hold(args: &[String]) -> Result<(Option<std::time::Duration>, &[String])> {
    match args.split_first() {
        Some((flag, rest)) if flag == "--hold" => {
            let (secs, rest) = rest.split_first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
            let secs: f64 = secs.parse().map_err(|_| anyhow::anyhow!("--hold takes seconds"))?;
            Ok((Some(std::time::Duration::from_secs_f64(secs)), rest))
        }
        _ => Ok((None, args)),
    }
}

/// Quoted for a POSIX shell only when it has to be, so a command line typed
/// by `run` reads as the user would have typed it.
fn shell_quote(arg: &str) -> String {
    const SPECIAL: &[char] = &[
        ' ', '\t', '"', '\'', '\\', '$', '`', '!', '(', ')', '{', '}', '[', ']', '|', '&', ';', '<', '>', '?', '*',
        '~', '#', '\n',
    ];
    if !arg.is_empty() && !arg.contains(SPECIAL) {
        return arg.to_string();
    }
    format!("'{}'", arg.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::shell_quote;

    #[test]
    fn quotes_only_what_needs_it() {
        assert_eq!(shell_quote("ls"), "ls");
        assert_eq!(shell_quote("-lic"), "-lic");
        assert_eq!(shell_quote("npm test"), "'npm test'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote(""), "''");
    }
}
