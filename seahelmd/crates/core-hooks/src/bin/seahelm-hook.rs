//! `seahelm-hook [<source>]`: the command hook agents run on every
//! lifecycle event, as the macOS app installs it (`~/.local/bin`). The
//! bridge itself is [`seahelm_core_hooks::wire::run`], shared with
//! `seahelm-core hook`.

fn main() {
    let source = std::env::args().nth(1);
    seahelm_core_hooks::wire::run(&seahelm_core_hooks::wire::socket_path_from_env(), source.as_deref());
    std::process::exit(0);
}
