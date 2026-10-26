#![cfg_attr(windows,windows_subsystem="windows")]
#[path="../discovery/mod.rs"]mod discovery;
#[cfg(windows)]
#[path="../discovery/service.rs"]mod service;
fn main(){
    use std::io::Write;
    #[cfg(windows)]let result=service::main();
    #[cfg(not(windows))]let result=Err::<(),String>("The optional NTFS component is Windows-only.".into());
    match result {
        Ok(())=>{if std::env::args().nth(1).as_deref()!=Some("--service"){let _=writeln!(std::io::stdout().lock(),"{}",serde_json::json!({"ok":true}));}},
        Err(message)=>{let _=writeln!(std::io::stderr().lock(),"{message}");let _=writeln!(std::io::stdout().lock(),"{}",serde_json::json!({"ok":false,"message":message}));std::process::exit(1);}
    }
}
