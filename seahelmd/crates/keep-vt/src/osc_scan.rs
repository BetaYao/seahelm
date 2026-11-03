//! Picks the OSC sequences seahelm acts on out of a PTY byte stream, beside
//! libghostty-vt rather than inside it: OSC 7501 (program status, which
//! upstream libghostty-vt does not know), OSC 133 (shell integration: the
//! shell has the terminal back), and OSC 9;4 (progress).
//!
//! The stream arrives in chunks cut anywhere, so a sequence may span calls;
//! the scanner carries the partial one over. A sequence longer than
//! [`MAX_OSC_BYTES`] is dropped rather than buffered without end.

/// The most of one OSC kept: 7501's whole-sequence limit, with room to spare
/// for the others.
pub const MAX_OSC_BYTES: usize = 4096;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Osc {
    /// The body after `7501;`, and whether it ended with BEL (a reply to a
    /// query goes back with the terminator the query used).
    ProgramStatus { body: Vec<u8>, bel: bool },
    /// OSC 133: `A` prompt start, `B` input start, `C` output start, `D`
    /// command finished (with its exit status, when given).
    Shell { mark: u8, exit: Option<i32> },
    /// OSC 9;4: state 0 clear, 1 set, 2 error, 3 indeterminate, 4 paused;
    /// percent when given.
    Progress { state: u8, percent: Option<u8> },
}

#[derive(Default)]
enum Phase {
    #[default]
    Ground,
    Esc,
    Osc,
    OscEsc,
}

#[derive(Default)]
pub struct Scanner {
    phase: Phase,
    buf: Vec<u8>,
    overflow: bool,
}

impl Scanner {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed the next chunk; the sequences it completes, in order, each with
    /// the offset just past its terminator in `data`. The offsets let a
    /// caller answer a query in its place among the others the terminal
    /// answers: programs send several at once and take the reply to the last
    /// (usually DA1) to mean "everything unanswered is unsupported".
    pub fn feed(&mut self, data: &[u8]) -> Vec<(usize, Osc)> {
        let mut out = Vec::new();
        for (i, &b) in data.iter().enumerate() {
            match self.phase {
                Phase::Ground => {
                    if b == 0x1b {
                        self.phase = Phase::Esc;
                    }
                }
                Phase::Esc => {
                    if b == b']' {
                        self.phase = Phase::Osc;
                        self.buf.clear();
                        self.overflow = false;
                    } else if b == 0x1b {
                        self.phase = Phase::Esc;
                    } else {
                        self.phase = Phase::Ground;
                    }
                }
                Phase::Osc => match b {
                    0x07 => {
                        self.finish(true, i + 1, &mut out);
                        self.phase = Phase::Ground;
                    }
                    0x1b => self.phase = Phase::OscEsc,
                    // CAN and SUB abort a sequence.
                    0x18 | 0x1a => self.phase = Phase::Ground,
                    _ => self.push(b),
                },
                Phase::OscEsc => {
                    if b == b'\\' {
                        self.finish(false, i + 1, &mut out);
                        self.phase = Phase::Ground;
                    } else {
                        // Any other escape ends the OSC unterminated; the
                        // ESC begins whatever comes next.
                        self.phase = if b == b']' {
                            self.buf.clear();
                            self.overflow = false;
                            Phase::Osc
                        } else {
                            Phase::Ground
                        };
                    }
                }
            }
        }
        out
    }

    fn push(&mut self, b: u8) {
        if self.buf.len() < MAX_OSC_BYTES {
            self.buf.push(b);
        } else {
            self.overflow = true;
        }
    }

    fn finish(&mut self, bel: bool, end: usize, out: &mut Vec<(usize, Osc)>) {
        if self.overflow {
            return;
        }
        let body = &self.buf;
        if let Some(rest) = body.strip_prefix(b"7501;") {
            out.push((end, Osc::ProgramStatus { body: rest.to_vec(), bel }));
        } else if let Some(rest) = body.strip_prefix(b"133;") {
            let mut parts = rest.split(|&c| c == b';');
            if let Some(&[mark]) = parts.next() {
                let exit = if mark == b'D' {
                    parts.next().and_then(|p| std::str::from_utf8(p).ok()).and_then(|p| p.parse().ok())
                } else {
                    None
                };
                out.push((end, Osc::Shell { mark, exit }));
            }
        } else if let Some(rest) = body.strip_prefix(b"9;4") {
            let mut parts = rest.split(|&c| c == b';').skip(1);
            let num = |p: Option<&[u8]>| p.and_then(|p| std::str::from_utf8(p).ok()).and_then(|p| p.parse::<u16>().ok());
            if rest.is_empty() || rest[0] == b';' {
                let state = num(parts.next()).unwrap_or(0).min(4) as u8;
                let percent = num(parts.next()).map(|p| p.min(100) as u8);
                out.push((end, Osc::Progress { state, percent }));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    trait Oscs {
        fn oscs(self) -> Vec<Osc>;
    }
    impl Oscs for Vec<(usize, Osc)> {
        fn oscs(self) -> Vec<Osc> {
            self.into_iter().map(|(_, o)| o).collect()
        }
    }

    #[test]
    fn each_sequence_says_where_it_ended() {
        let mut s = Scanner::new();
        let data = b"ab\x1b]7501;?\x07\x1b[c\x1b]133;D\x1b\\z";
        let ends: Vec<usize> = s.feed(data).into_iter().map(|(e, _)| e).collect();
        assert_eq!(ends, vec![11, 23]);
        assert_eq!(&data[..11], b"ab\x1b]7501;?\x07");
    }

    #[test]
    fn finds_7501_with_either_terminator() {
        let mut s = Scanner::new();
        let got = s.feed(b"hi\x1b]7501;state=idle\x1b\\there\x1b]7501;?\x07").oscs();
        assert_eq!(
            got,
            vec![
                Osc::ProgramStatus { body: b"state=idle".to_vec(), bel: false },
                Osc::ProgramStatus { body: b"?".to_vec(), bel: true },
            ]
        );
    }

    #[test]
    fn a_sequence_split_across_chunks_is_carried_over() {
        let mut s = Scanner::new();
        let whole = b"\x1b]7501;state=working:app=cargo\x1b\\";
        for cut in 1..whole.len() {
            let mut got = s.feed(&whole[..cut]).oscs();
            got.extend(s.feed(&whole[cut..]).oscs());
            assert_eq!(got, vec![Osc::ProgramStatus { body: b"state=working:app=cargo".to_vec(), bel: false }], "cut at {cut}");
        }
    }

    #[test]
    fn shell_marks_and_exit_status() {
        let mut s = Scanner::new();
        let got = s.feed(b"\x1b]133;A\x07\x1b]133;C\x07\x1b]133;D;127\x07\x1b]133;D\x07").oscs();
        assert_eq!(
            got,
            vec![
                Osc::Shell { mark: b'A', exit: None },
                Osc::Shell { mark: b'C', exit: None },
                Osc::Shell { mark: b'D', exit: Some(127) },
                Osc::Shell { mark: b'D', exit: None },
            ]
        );
    }

    #[test]
    fn progress() {
        let mut s = Scanner::new();
        let got = s.feed(b"\x1b]9;4;1;40\x07\x1b]9;4;3\x07\x1b]9;4;0;0\x1b\\\x1b]9;hello\x07").oscs();
        assert_eq!(
            got,
            vec![
                Osc::Progress { state: 1, percent: Some(40) },
                Osc::Progress { state: 3, percent: None },
                Osc::Progress { state: 0, percent: Some(0) },
            ],
            "OSC 9 notifications are not progress"
        );
    }

    #[test]
    fn other_oscs_and_overlong_ones_are_ignored() {
        let mut s = Scanner::new();
        assert!(s.feed(b"\x1b]0;title\x07\x1b]8;;http://x\x1b\\").is_empty());
        let mut long = b"\x1b]7501;state=idle:".to_vec();
        long.extend(std::iter::repeat_n(b'x', MAX_OSC_BYTES));
        long.extend(b"\x1b\\");
        assert!(s.feed(&long).is_empty());
        assert_eq!(s.feed(b"\x1b]133;D\x07").len(), 1, "the scanner recovers");
    }

    #[test]
    fn can_aborts_and_a_new_osc_after_an_unterminated_one_still_counts() {
        let mut s = Scanner::new();
        assert!(s.feed(b"\x1b]7501;state=idle\x18").is_empty());
        let got = s.feed(b"\x1b]0;x\x1b]133;D;0\x07").oscs();
        assert_eq!(got, vec![Osc::Shell { mark: b'D', exit: Some(0) }]);
    }
}
