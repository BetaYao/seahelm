//! Replay bytes into a terminal and say what it shows: for the tests that
//! check what a client wrote to its terminal (tools/keeper-test.sh).
//!
//!   replay <cols> <rows> <file> [<more bytes, with \e for escape>]
//!
//! Prints, one per line: `alternate yes|no`, `title <title>`, `kitty <flags>`,
//! `history <rows>`, then `text` and the whole screen as plain text, history
//! first. With a second argument, the bytes it names are
//! written after the file's (to leave an alternate screen, say) and the
//! report is about what that leaves.

use keep_vt::{Format, Terminal};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cols: u16 = args.get(1).and_then(|a| a.parse().ok()).expect("cols");
    let rows: u16 = args.get(2).and_then(|a| a.parse().ok()).expect("rows");
    let bytes = std::fs::read(args.get(3).expect("file")).expect("read");
    let mut terminal = Terminal::new(cols, rows).expect("terminal");
    terminal.set_scrollback_limit(10_000_000).expect("scrollback");
    terminal.write(&bytes);
    if let Some(more) = args.get(4) {
        terminal.write(more.replace("\\e", "\x1b").as_bytes());
    }
    println!("alternate {}", if terminal.alternate_screen().is_some() { "yes" } else { "no" });
    println!("title {}", terminal.title());
    println!("kitty {}", terminal.kitty_keyboard_flags());
    println!("history {}", terminal.scrollback_rows());
    println!("text");
    print!("{}", String::from_utf8_lossy(&terminal.snapshot(Format::Plain).expect("text")));
    println!();
}
