use serde::{Deserialize, Serialize};
use std::{collections::{BTreeMap, VecDeque}, sync::{Arc, Condvar, Mutex, atomic::{AtomicBool, Ordering}}, time::{Duration, Instant}};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all="snake_case")]
pub enum MediaKind { Ssd, Hdd, #[default] Unknown }
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all="camelCase")]
pub struct Topology {
    pub disks: Vec<u32>,
    pub known: bool,
    pub media: MediaKind,
}
#[derive(Clone, Debug)]
pub struct Resource { pub volume: String, pub topology: Topology }
#[derive(Clone, Copy)]
pub enum Mode { Scan, Metadata }
struct State { next: u64, waiting: VecDeque<(u64, Resource)>, active: BTreeMap<u64, Resource> }
pub struct Gate { mode: Mode, limit: usize, state: Mutex<State>, changed: Condvar }
pub struct Ticket { gate: Arc<Gate>, id: u64 }
pub struct Lease { gate: Arc<Gate>, id: u64 }
fn overlaps(a:&Resource,b:&Resource)->bool {
    a.volume==b.volume || !a.topology.known || !b.topology.known ||
        a.topology.disks.iter().any(|d| b.topology.disks.contains(d))
}
impl Gate {
    pub fn new(mode:Mode)->Arc<Self> {
        Arc::new(Self{mode,limit:match mode{Mode::Scan=>2,Mode::Metadata=>4},
            state:Mutex::new(State{next:0,waiting:VecDeque::new(),active:BTreeMap::new()}),changed:Condvar::new()})
    }
    pub fn request(self:&Arc<Self>,resource:Resource)->Ticket {
        let mut state=self.state.lock().unwrap();state.next+=1;let id=state.next;
        state.waiting.push_back((id,resource));Ticket{gate:self.clone(),id}
    }
    fn admissible(&self,state:&State,id:u64)->bool {
        let Some((_,resource))=state.waiting.iter().find(|(ticket,_)|*ticket==id)else{return false};
        if state.active.len()>=self.limit{return false}
        // An earlier conflicting request gets the next slot; unrelated disks can pass it.
        for (earlier,other) in &state.waiting {
            if *earlier==id { break }
            if overlaps(resource,other) { return false }
        }
        let conflicting:Vec<_>=state.active.values().filter(|other|overlaps(resource,other)).collect();
        match self.mode {
            Mode::Scan=>conflicting.is_empty(),
            Mode::Metadata=>{
                if !resource.topology.known || conflicting.iter().any(|r|!r.topology.known) { return conflicting.is_empty() }
                let limit=if resource.topology.media==MediaKind::Ssd &&
                    conflicting.iter().all(|r|r.topology.media==MediaKind::Ssd){2}else{1};
                conflicting.len()<limit
            }
        }
    }
}
impl Ticket {
    pub fn try_start(&self)->Option<Lease> {
        let mut state=self.gate.state.lock().unwrap();
        if !self.gate.admissible(&state,self.id){return None}
        let position=state.waiting.iter().position(|(id,_)|*id==self.id)?;
        let (_,resource)=state.waiting.remove(position)?;
        state.active.insert(self.id,resource);
        self.gate.changed.notify_all();
        Some(Lease{gate:self.gate.clone(),id:self.id})
    }
    pub fn wait(&self,cancel:&AtomicBool,timeout:Duration)->Result<Lease,String> {
        let started=Instant::now();
        loop {
            if cancel.load(Ordering::SeqCst){return Err("Discovery cancelled.".into())}
            if let Some(lease)=self.try_start(){return Ok(lease)}
            if started.elapsed()>=timeout{return Err("Another scan is using this physical disk. Retry discovery when it finishes.".into())}
            let lock=self.gate.state.lock().unwrap();
            let _=self.gate.changed.wait_timeout(lock,Duration::from_millis(25)).unwrap();
        }
    }
}
impl Drop for Ticket {
    fn drop(&mut self){
        self.gate.state.lock().unwrap().waiting.retain(|(id,_)|*id!=self.id);
        self.gate.changed.notify_all();
    }
}
impl Drop for Lease {
    fn drop(&mut self){self.gate.state.lock().unwrap().active.remove(&self.id);self.gate.changed.notify_all();}
}
#[cfg(test)]
mod tests {
    use super::*;
    fn resource(volume:&str,disks:&[u32],media:MediaKind)->Resource {
        Resource{volume:volume.into(),topology:Topology{disks:disks.into(),known:!disks.is_empty(),media}}
    }
    #[test]
    fn partitions_share_disks_and_multi_disk_reservations_are_atomic(){
        let gate=Gate::new(Mode::Scan);
        let a=gate.request(resource("a",&[1],MediaKind::Ssd));let first=a.try_start().unwrap();
        let b=gate.request(resource("b",&[1,2],MediaKind::Ssd));assert!(b.try_start().is_none());
        let c=gate.request(resource("c",&[3],MediaKind::Ssd));let third=c.try_start().unwrap();
        let d=gate.request(resource("d",&[2],MediaKind::Ssd));assert!(d.try_start().is_none());
        drop(first);let second=b.try_start().unwrap();assert!(d.try_start().is_none());
        drop(second);drop(third);assert!(d.try_start().is_some());
    }
    #[test]
    fn unknown_topology_serializes_and_cancelled_waiters_release_the_queue(){
        let gate=Gate::new(Mode::Scan);
        let a=gate.request(resource("unknown",&[],MediaKind::Unknown));let first=a.try_start().unwrap();
        let b=gate.request(resource("ssd",&[3],MediaKind::Ssd));assert!(b.try_start().is_none());
        drop(first);assert!(b.try_start().is_some());
        let c=gate.request(resource("cancelled",&[4],MediaKind::Ssd));
        assert!(c.wait(&AtomicBool::new(true),Duration::from_secs(1)).is_err());
        drop(c);
        assert!(gate.request(resource("later",&[4],MediaKind::Ssd)).try_start().is_some());
    }
    #[test]
    fn metadata_respects_hdd_ssd_and_global_limits(){
        let gate=Gate::new(Mode::Metadata);
        let h=gate.request(resource("hdd",&[1],MediaKind::Hdd));let h1=h.try_start().unwrap();
        let h2=gate.request(resource("partition",&[1],MediaKind::Hdd));assert!(h2.try_start().is_none());
        let s=gate.request(resource("ssd",&[2],MediaKind::Ssd));let s1=s.try_start().unwrap();
        let s=gate.request(resource("ssd",&[2],MediaKind::Ssd));let s2=s.try_start().unwrap();
        let s3=gate.request(resource("ssd",&[2],MediaKind::Ssd));assert!(s3.try_start().is_none());
        let d=gate.request(resource("other",&[3],MediaKind::Ssd));let d1=d.try_start().unwrap();
        assert!(gate.request(resource("last",&[4],MediaKind::Ssd)).try_start().is_none());
        drop(h1);drop(h2);drop(s1);drop(s2);drop(d1);
    }
}
