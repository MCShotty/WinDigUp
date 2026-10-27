use serde::{Deserialize,Serialize};
use std::{path::PathBuf,sync::{Arc,Mutex,mpsc},time::{SystemTime,UNIX_EPOCH}};
#[derive(Clone,Debug,Serialize,Deserialize)]
#[serde(default,rename_all="camelCase")]
pub struct Options {pub pinned:Vec<String>,pub show_recent:bool}
impl Default for Options{fn default()->Self{Self{pinned:vec![],show_recent:true}}}
#[derive(Clone,Serialize,Deserialize)]struct Recent{id:String,at:u64}
#[derive(Default,Serialize,Deserialize)]struct Saved{version:u32,entries:Vec<Recent>}
pub struct History{entries:Arc<Mutex<Vec<Recent>>>,writer:mpsc::SyncSender<Option<mpsc::Sender<Result<(),String>>>>}
fn now()->u64{SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()}
pub fn valid_id(id:&str)->bool{id.starts_with("app:")&&id.len()<=128&&!id.contains('\0')}
fn prune(entries:&mut Vec<Recent>){let time=now();entries.retain(|e|valid_id(&e.id)&&e.at<=time&&time-e.at<=90*86400);entries.truncate(64);}
pub fn visible_ids(options:&Options,recent:Vec<String>,visible:&std::collections::HashSet<String>)->Vec<String>{
    let mut ids=options.pinned.clone();if options.show_recent{ids.extend(recent);}
    let mut used=std::collections::HashSet::new();
    ids.into_iter().filter(|id|visible.contains(id)&&used.insert(id.clone())).take(6).collect()
}
impl History{
    pub fn new(path:PathBuf)->Self{
        let mut entries=std::fs::read(&path).ok().filter(|b|b.len()<=32000)
            .and_then(|b|serde_json::from_slice::<Saved>(&b).ok()).filter(|s|s.version==1).map(|s|s.entries).unwrap_or_default();
        prune(&mut entries);let entries=Arc::new(Mutex::new(entries));
        let (writer,reader)=mpsc::sync_channel::<Option<mpsc::Sender<Result<(),String>>>>(1);
        let weak=Arc::downgrade(&entries);
        std::thread::spawn(move||{while let Ok(message)=reader.recv(){
            let mut replies=message.into_iter().collect::<Vec<_>>();
            while let Ok(message)=reader.try_recv(){replies.extend(message);}
            let Some(entries)=weak.upgrade()else{break};
            let result=(||{
                // Keep clear and persistence ordered, including already queued launch updates.
                let snapshot={let mut guard=entries.lock().unwrap();prune(&mut guard);guard.clone()};
                if let Some(parent)=path.parent(){std::fs::create_dir_all(parent).map_err(|e|e.to_string())?}
                let bytes=serde_json::to_vec(&Saved{version:1,entries:snapshot}).map_err(|e|e.to_string())?;
                let tmp=path.with_extension("json.new");std::fs::write(&tmp,bytes).map_err(|e|e.to_string())?;
                std::fs::rename(tmp,&path).map_err(|e|e.to_string())
            })();for reply in replies{let _=reply.send(result.clone());}
        }});
        Self{entries,writer}
    }
    pub fn accepted(&self,id:&str){
        if !valid_id(id){return}
        let mut entries=self.entries.lock().unwrap();entries.retain(|e|e.id!=id);entries.insert(0,Recent{id:id.into(),at:now()});prune(&mut entries);drop(entries);
        let _=self.writer.try_send(None);
    }
    pub fn ids(&self)->Vec<String>{let mut e=self.entries.lock().unwrap();prune(&mut e);e.iter().map(|e|e.id.clone()).collect()}
    pub fn clear(&self)->Result<(),String>{
        self.entries.lock().unwrap().clear();let(reply,wait)=mpsc::channel();
        self.writer.send(Some(reply)).map_err(|e|e.to_string())?;wait.recv().map_err(|e|e.to_string())?
    }
}
#[cfg(test)]mod tests{
    use super::*;
    #[test]fn pins_precede_recents_and_unavailable_entries_are_filtered(){
        let options=Options{pinned:vec!["app:missing".into(),"app:second".into()],show_recent:true};
        let visible=["app:first","app:second","app:third"].into_iter().map(String::from).collect();
        assert_eq!(visible_ids(&options,vec!["app:first".into(),"app:second".into(),"app:third".into()],&visible),
            ["app:second","app:first","app:third"]);
        assert_eq!(visible_ids(&Options{show_recent:false,..options},vec!["app:first".into()],&visible),["app:second"]);
        let many=(0..20).map(|i|format!("app:{i}")).collect::<Vec<_>>();
        assert_eq!(visible_ids(&Options::default(),many.clone(),&many.into_iter().collect()).len(),6);
    }
    #[test]fn corrupt_or_incompatible_history_recovers_without_query_data(){
        let path=std::env::temp_dir().join(format!("digup-recents-corrupt-{}-{}.json",std::process::id(),now()));
        for bytes in [b"corrupt".as_slice(),br#"{"version":2,"entries":[{"id":"app:old","at":0}]}"#.as_slice()]{
            std::fs::write(&path,bytes).unwrap();let h=History::new(path.clone());assert!(h.ids().is_empty());h.clear().unwrap();
        }
        let _=std::fs::remove_file(path);
    }
    #[test]fn recents_deduplicate_and_clear_without_query_text(){
        let path=std::env::temp_dir().join(format!("digup-recents-{}-{}.json",std::process::id(),now()));
        let h=History::new(path.clone());h.accepted("app:first");h.accepted("app:second");h.accepted("app:first");h.accepted("file:C:/secret.txt");
        assert_eq!(h.ids(),["app:first","app:second"]);h.clear().unwrap();assert!(h.ids().is_empty());
        assert!(History::new(path.clone()).ids().is_empty());let _=std::fs::remove_file(path);
    }
}
