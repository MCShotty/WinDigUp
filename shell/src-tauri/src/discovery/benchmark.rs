use super::{store::{CandidateStore, VolumeStore}, Candidate, ntfs::{FileId, Record}};
use serde_json::json;
use std::time::Instant;

#[test]
#[ignore = "Measured storage fixture, run explicitly on a recorded runner"]
fn baseline() {
    let root = std::env::temp_dir().join(format!("digup-discovery-baseline-{}-{}", std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
    std::fs::create_dir_all(&root).unwrap();
    let mut report = json!({"fixture":true,"version":1,"os":std::env::consts::OS,
        "arch":std::env::consts::ARCH,"candidates":2000,"records":40000});
    {
        let inventory = VolumeStore::open(&root.join("volume.sqlite")).unwrap();
        let id = |number:u64| { let mut bytes=[0;16]; bytes[..8].copy_from_slice(&number.to_le_bytes()); FileId(bytes) };
        let started = Instant::now();
        for batch in 0..40u64 {
            let records:Vec<_>=(0..1000).map(|offset| {
                let number=2+batch*1000+offset;
                Record{id:id(number),parent:id(1),name:format!("entry-{number}.exe"),usn:1,reason:0,attributes:0}
            }).collect();
            inventory.apply(&records,false).unwrap();
        }
        report["inventoryCommitMs"]=json!(started.elapsed().as_secs_f64()*1000.0);
        let started=Instant::now();
        for number in 2..2002 { assert!(inventory.path(&id(number).text(),"V:\\",&id(1).text()).unwrap().is_some()); }
        report["pathResolutionMs"]=json!(started.elapsed().as_secs_f64()*1000.0);
        let candidates=CandidateStore::open(&root.join("candidates.sqlite")).unwrap();
        let started=Instant::now();
        for number in 0..2000 {
            candidates.save(&Candidate{id:format!("exe:{number:064x}"),volume:"fixture".into(),
                path:format!("V:\\Applications\\App {number}.exe"),name:format!("App {number}"),
                classification:"accepted".into(),..Candidate::default()},"fixture").unwrap();
        }
        report["candidateCommitMs"]=json!(started.elapsed().as_secs_f64()*1000.0);
        let batched=CandidateStore::open(&root.join("batched-candidates.sqlite")).unwrap();
        let values:Vec<_>=(0..2000).map(|number|Candidate{id:format!("exe:{number:064x}"),volume:"fixture".into(),
            path:format!("V:\\Applications\\App {number}.exe"),name:format!("App {number}"),
            classification:"accepted".into(),..Candidate::default()}).collect();
        let started=Instant::now();
        for records in values.chunks(64){batched.save_batch(records,"fixture").unwrap();}
        report["batchedCandidateCommitMs"]=json!(started.elapsed().as_secs_f64()*1000.0);
        assert_eq!(batched.accepted().unwrap().len(),2000);
        let started=Instant::now();
        assert_eq!(candidates.accepted().unwrap().len(),2000);
        report["catalogReadMs"]=json!(started.elapsed().as_secs_f64()*1000.0);
    }
    println!("DISCOVERY_BASELINE={report}");
    std::fs::remove_dir_all(root).unwrap();
}
