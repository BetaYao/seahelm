fn main(){
    println!("Rust ScreenExtra      = {}", std::mem::size_of::<keep_vt::ffi::ScreenExtra>());
    println!("Rust TerminalExtra    = {}", std::mem::size_of::<keep_vt::ffi::TerminalExtra>());
    println!("Rust FormatterOptions = {}", std::mem::size_of::<keep_vt::ffi::FormatterOptions>());
}
