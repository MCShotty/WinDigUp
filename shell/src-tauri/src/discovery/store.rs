use super::{db::{Database,Value},ntfs::{FileId,Record},Candidate};
use std::path::Path;

/// Durable per-volume inventory. Batch transactions are committed before a journal checkpoint advances.
pub struct VolumeStore {pub db:Database}
impl VolumeStore {
    pub fn open(path:&Path)->Result<Self,String> {
        let db=Database::open(path,false)?;
        let version=db.rows("PRAGMA user_version",&[])?.first().and_then(|r|r[0].parse::<u32>().ok()).unwrap_or(0);
        if version>1{return Err("NTFS inventory belongs to a newer DigUp version.".into())}
        db.run("PRAGMA journal_mode=WAL",&[])?;
        db.run("PRAGMA cache_size=-8192",&[])?;
        db.run("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)",&[])?;
        db.run("CREATE TABLE IF NOT EXISTS nodes(id TEXT PRIMARY KEY,parent TEXT NOT NULL,name TEXT NOT NULL,attrs INTEGER NOT NULL,usn INTEGER NOT NULL,executable INTEGER NOT NULL)",&[])?;
        db.run("CREATE INDEX IF NOT EXISTS executable_nodes ON nodes(executable)",&[])?;
        db.run("CREATE INDEX IF NOT EXISTS parent_nodes ON nodes(parent)",&[])?;
        db.run("CREATE TABLE IF NOT EXISTS launch_links(file_id TEXT NOT NULL,parent TEXT NOT NULL,name TEXT NOT NULL,identity TEXT NOT NULL,PRIMARY KEY(file_id,parent,name))",&[])?;
        db.run("CREATE TABLE IF NOT EXISTS pending_renames(file_id TEXT PRIMARY KEY,parent TEXT NOT NULL,name TEXT NOT NULL)",&[])?;
        db.run("PRAGMA user_version=1",&[])?;
        Ok(Self{db})
    }
    pub fn get(&self,key:&str)->Result<Option<String>,String>{
        Ok(self.db.rows("SELECT value FROM meta WHERE key=?",&[Value::Text(key)])?.first().and_then(|r|r.first()).cloned())
    }
    pub fn put(&self,key:&str,value:&str)->Result<(),String>{
        self.db.run("INSERT INTO meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",&[Value::Text(key),Value::Text(value)])
    }
    pub fn clear(&self)->Result<(),String> {
        self.db.run("DELETE FROM nodes",&[])?;self.put("complete","false")
    }
    pub fn apply(&self,records:&[Record],deleted:bool)->Result<(),String> {
        self.db.run("BEGIN IMMEDIATE",&[])?;
        let result=(||{
            for r in records {
                let id=r.id.text();let parent=r.parent.text();
                if deleted&&r.reason&0x1000!=0 {
                    self.db.run("INSERT INTO pending_renames VALUES(?,?,?) ON CONFLICT(file_id) DO UPDATE SET parent=excluded.parent,name=excluded.name",&[Value::Text(&id),Value::Text(&parent),Value::Text(&r.name)])?;
                }
                if deleted&&r.reason&0x2000!=0 {
                    if let Some(old)=self.db.rows("SELECT parent,name FROM pending_renames WHERE file_id=?",&[Value::Text(&id)])?.first(){
                        self.db.run("DELETE FROM launch_links WHERE file_id=? AND parent=? AND name=?",&[Value::Text(&id),Value::Text(&parent),Value::Text(&r.name)])?;
                        self.db.run("UPDATE launch_links SET parent=?,name=? WHERE file_id=? AND parent=? AND name=?",&[Value::Text(&parent),Value::Text(&r.name),Value::Text(&id),Value::Text(&old[0]),Value::Text(&old[1])])?;
                        self.db.run("DELETE FROM pending_renames WHERE file_id=?",&[Value::Text(&id)])?;
                    }
                }
                if deleted&&r.reason&0x200!=0 {
                    self.db.run("DELETE FROM nodes WHERE id=?",&[Value::Text(&id)])?;
                }else{
                    self.db.run("INSERT INTO nodes VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET parent=excluded.parent,name=excluded.name,attrs=excluded.attrs,usn=excluded.usn,executable=excluded.executable",
                        &[Value::Text(&id),Value::Text(&parent),Value::Text(&r.name),Value::Integer(r.attributes as i64),Value::Integer(r.usn),Value::Integer(i64::from(r.executable()))])?;
                }
            }
            self.db.run("COMMIT",&[])
        })();
        if result.is_err(){let _=self.db.run("ROLLBACK",&[]);}result
    }
    pub fn path(&self,id:&str,volume:&str,root:&str)->Result<Option<String>,String> {
        let mut current=id.to_string();let mut names=vec![];let mut seen=std::collections::HashSet::new();
        for _ in 0..256 {
            if current==root {names.reverse();return Ok(Some(format!("{}{}",volume,names.join("\\"))))}
            if !seen.insert(current.clone()){return Ok(None)}
            let rows=self.db.rows("SELECT parent,name,attrs FROM nodes WHERE id=?",&[Value::Text(&current)])?;
            let Some(row)=rows.first()else{return Ok(None)};
            let attrs=row[2].parse::<u32>().unwrap_or(0);
            // Never traverse reparse points into another namespace or hydrate placeholders.
            if attrs&0x400!=0||attrs&0x1000!=0||row[1]=="."||row[1]==".." {return Ok(None)}
            names.push(row[1].clone());current=row[0].clone();
        }
        Ok(None)
    }
    pub fn launch_identity(&self,volume:&str,file:&str,parent:&str,name:&str)->Result<String,String>{
        if let Some(row)=self.db.rows("SELECT identity FROM launch_links WHERE file_id=? AND parent=? AND name=?",
            &[Value::Text(file),Value::Text(parent),Value::Text(name)])?.first(){return Ok(row[0].clone())}
        use sha2::{Digest,Sha256};
        let identity=format!("exe:{:x}",Sha256::digest(format!("{volume}|{file}|{parent}|{name}").as_bytes()));
        self.db.run("INSERT INTO launch_links VALUES(?,?,?,?)",&[Value::Text(file),Value::Text(parent),Value::Text(name),Value::Text(&identity)])?;
        Ok(identity)
    }
    pub fn executable_ids(&self,after:&str,limit:usize)->Result<Vec<String>,String> {
        Ok(self.db.rows("SELECT id FROM nodes WHERE executable=1 AND id>? ORDER BY id LIMIT ?",
            &[Value::Text(after),Value::Integer(limit.clamp(1,1000)as i64)])?.into_iter().map(|r|r[0].clone()).collect())
    }
}

/// User-owned candidates. Reconciliation only removes entries after a complete, successful source pass.
pub struct CandidateStore {db:Database}
impl CandidateStore {
    pub fn open(path:&Path)->Result<Self,String> {
        let db=Database::open(path,false)?;
        let version=db.rows("PRAGMA user_version",&[])?.first().and_then(|r|r[0].parse::<u32>().ok()).unwrap_or(0);
        if version>1{return Err("Executable catalog belongs to a newer DigUp version.".into())}
        db.run("PRAGMA journal_mode=WAL",&[])?;
        db.run("CREATE TABLE IF NOT EXISTS candidates(id TEXT PRIMARY KEY,volume TEXT NOT NULL,revision TEXT NOT NULL,record TEXT NOT NULL,classification TEXT NOT NULL,name TEXT NOT NULL)",&[])?;
        db.run("CREATE INDEX IF NOT EXISTS candidates_volume ON candidates(volume)",&[])?;
        db.run("CREATE TABLE IF NOT EXISTS discovery_meta(volume TEXT PRIMARY KEY,revision TEXT NOT NULL)",&[])?;
        db.run("PRAGMA user_version=1",&[])?;Ok(Self{db})
    }
    pub fn save(&self,record:&Candidate,revision:&str)->Result<(),String> {
        let json=serde_json::to_string(record).map_err(|e|e.to_string())?;
        self.db.run("INSERT INTO candidates VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,record=excluded.record,classification=excluded.classification,name=excluded.name",
            &[Value::Text(&record.id),Value::Text(&record.volume),Value::Text(revision),Value::Text(&json),Value::Text(&record.classification),Value::Text(&record.name)])
    }
    pub fn finish(&self,volume:&str,revision:&str)->Result<(),String> {
        self.db.run("DELETE FROM candidates WHERE volume=? AND revision!=?",&[Value::Text(volume),Value::Text(revision)])
    }
    pub fn revision(&self,volume:&str)->Result<String,String>{
        Ok(self.db.rows("SELECT revision FROM discovery_meta WHERE volume=?",&[Value::Text(volume)])?.first().map(|r|r[0].clone()).unwrap_or_default())
    }
    pub fn set_revision(&self,volume:&str,revision:&str)->Result<(),String>{
        self.db.run("INSERT INTO discovery_meta VALUES(?,?) ON CONFLICT(volume) DO UPDATE SET revision=excluded.revision",
            &[Value::Text(volume),Value::Text(revision)])
    }
    pub fn read(path:&Path)->Result<Self,String>{Ok(Self{db:Database::open(path,true)?})}
    pub fn get(&self,id:&str)->Result<Option<Candidate>,String> {
        self.db.rows("SELECT record FROM candidates WHERE id=?",&[Value::Text(id)])?.first()
            .map(|r|serde_json::from_str(&r[0]).map_err(|e|e.to_string())).transpose()
    }
    pub fn list(&self,query:&str,classification:&str,offset:usize,limit:usize)->Result<(Vec<Candidate>,usize),String> {
        let escaped=query.replace('\\',"\\\\").replace('%',"\\%").replace('_',"\\_");
        let pattern=format!("%{}%",escaped);
        let values=[Value::Text(&pattern),Value::Text(classification),Value::Text(classification)];
        let total=self.db.rows("SELECT count(*) FROM candidates WHERE name LIKE ? ESCAPE '\\' AND (?='all' OR classification=?)",&values)?
            .first().and_then(|r|r[0].parse().ok()).unwrap_or(0);
        let records=self.db.rows("SELECT record FROM candidates WHERE name LIKE ? ESCAPE '\\' AND (?='all' OR classification=?) ORDER BY name COLLATE NOCASE,id LIMIT ? OFFSET ?",
            &[Value::Text(&pattern),Value::Text(classification),Value::Text(classification),Value::Integer(limit.clamp(1,100)as i64),Value::Integer(offset.min(1_000_000)as i64)])?
            .into_iter().map(|r|serde_json::from_str(&r[0]).map_err(|e|e.to_string())).collect::<Result<Vec<_>,_>>()?;
        Ok((records,total))
    }
    pub fn accepted(&self)->Result<Vec<Candidate>,String> {
        self.db.rows("SELECT record FROM candidates WHERE classification='accepted' ORDER BY id",&[])?
            .into_iter().map(|r|serde_json::from_str(&r[0]).map_err(|e|e.to_string())).collect()
    }
}
#[cfg(test)]mod tests {
    use super::*;
    fn file()->std::path::PathBuf {std::env::temp_dir().join(format!("digup-inventory-{}-{}.sqlite",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()))}
    fn id(value:u8)->FileId {let mut bytes=[0;16];bytes[0]=value;FileId(bytes)}
    #[test]fn moves_deletions_and_cycles_resolve_without_traversing_reparse_points(){
        let file=file();
        {
            let store=VolumeStore::open(&file).unwrap();
            let record=|value,parent,name:&str,attrs|Record{id:id(value),parent:id(parent),usn:1,reason:0,attributes:attrs,name:name.into()};
            store.apply(&[record(2,1,"Portable",16),record(3,2,"写真.exe",0)],false).unwrap();
            assert_eq!(store.path(&id(3).text(),r"\\?\Volume{a}\",&id(1).text()).unwrap().unwrap(),r"\\?\Volume{a}\Portable\写真.exe");
            store.apply(&[record(2,1,"Moved",16)],true).unwrap();
            assert!(store.path(&id(3).text(),"V:\\",&id(1).text()).unwrap().unwrap().contains("Moved"));
            store.apply(&[record(2,3,"Cycle",16)],true).unwrap();
            assert!(store.path(&id(3).text(),"V:\\",&id(1).text()).unwrap().is_none());
            store.apply(&[record(2,1,"Link",16|0x400)],true).unwrap();
            assert!(store.path(&id(3).text(),"V:\\",&id(1).text()).unwrap().is_none());
            let mut deleted=record(3,2,"写真.exe",0);deleted.reason=0x200;store.apply(&[deleted],true).unwrap();
            assert!(store.executable_ids("",100).unwrap().is_empty());
        }
        let _=std::fs::remove_file(file);
    }
    #[test]fn distinct_hard_link_names_and_rename_pairs_preserve_identity(){
        let file=file();
        {
            let store=VolumeStore::open(&file).unwrap();
            let first=store.launch_identity("v",&id(3).text(),&id(2).text(),"Editor.exe").unwrap();
            let variant=store.launch_identity("v",&id(3).text(),&id(2).text(),"Helper.exe").unwrap();
            assert_ne!(first,variant,"Same file and directory do not establish identical launch semantics.");
            let old=Record{id:id(3),parent:id(2),name:"Editor.exe".into(),usn:10,reason:0x1000,attributes:0};
            let new=Record{id:id(3),parent:id(4),name:"Renamed.exe".into(),usn:11,reason:0x2000,attributes:0};
            store.apply(&[old],true).unwrap();store.apply(&[new],true).unwrap();
            assert_eq!(store.launch_identity("v",&id(3).text(),&id(4).text(),"Renamed.exe").unwrap(),first);
        }
        let _=std::fs::remove_file(file);
    }
    #[test]fn failed_partial_refresh_keeps_previous_candidates(){
        let file=file();
        {
            let db=CandidateStore::open(&file).unwrap();
            let c=Candidate{id:"exe:one".into(),volume:"volume".into(),name:"Editor".into(),classification:"accepted".into(),..Candidate::default()};
            db.save(&c,"old").unwrap();
            assert_eq!(db.list("Editor","all",0,10).unwrap().1,1);
            assert_eq!(db.accepted().unwrap().len(),1);
            assert_eq!(db.get("exe:one").unwrap().unwrap().name,"Editor");
            db.finish("other","new").unwrap();assert!(db.get("exe:one").unwrap().is_some());
            db.finish("volume","new").unwrap();assert!(db.get("exe:one").unwrap().is_none());
        }
        let _=std::fs::remove_file(file);
    }
}
