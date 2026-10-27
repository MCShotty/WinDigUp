#[cfg(windows)]
fn main(){
 use digup_application_fixtures::system_settings::{Catalog,Options};
 use std::time::{Instant,Duration};
 let root=std::env::args().nth(1).expect("provide an isolated catalog path");
 let mut catalog=Catalog::new(Options{enabled:true,semantic_enabled:false,ordinary_searches:true});
 catalog.attach(root.into(),|_|{});catalog.start();
 let started=Instant::now();
 while catalog.info()["refreshing"]==true&&started.elapsed()<Duration::from_secs(40){std::thread::sleep(Duration::from_millis(50));}
 let hits=catalog.search("");
 assert!(hits.iter().any(|h|h.source=="control_panel"),"Real Shell enumeration returned no Control Panel items: {}",catalog.info());
 let sound=catalog.search("classic Sound").into_iter().find(|h|h.source=="control_panel").expect("Classic Sound was not discovered");
 catalog.launch(&sound.id).expect("Windows rejected native Control Panel activation");
 println!("{}",serde_json::json!({"nativeOnly":true,"controlPanelItems":hits.iter().filter(|h|h.source=="control_panel").count(),"launchAccepted":true,"catalog":catalog.info()}));
}
#[cfg(not(windows))]fn main(){eprintln!("This integration harness requires Windows.");std::process::exit(2);}
