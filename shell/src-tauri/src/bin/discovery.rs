#![cfg_attr(windows,windows_subsystem="windows")]
#[path="../discovery/mod.rs"]mod discovery;
#[cfg(windows)]
#[path="../discovery/service.rs"]mod service;
fn main(){
    #[cfg(windows)]let result=service::main();
    #[cfg(not(windows))]let result=Err::<(),String>("The optional NTFS component is Windows-only.".into());
    match result {
        Ok(())=>println!("{}",serde_json::json!({"ok":true})),
        Err(message)=>{eprintln!("{message}");println!("{}",serde_json::json!({"ok":false,"message":message}));std::process::exit(1);}
    }
}
