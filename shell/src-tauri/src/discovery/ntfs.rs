//! Pure, bounded USN parser. No raw NTFS structures or executable code are loaded.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct FileId(pub [u8;16]);
impl FileId {
    pub fn text(self)->String {self.0.iter().map(|b|format!("{b:02x}")).collect()}
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub id:FileId,pub parent:FileId,pub usn:i64,pub reason:u32,pub attributes:u32,pub name:String,
}
impl Record {
    pub fn directory(&self)->bool {self.attributes&0x10!=0}
    pub fn executable(&self)->bool {!self.directory()&&self.name.to_lowercase().ends_with(".exe")}
}
fn u16_at(bytes:&[u8],offset:usize)->u16 {u16::from_le_bytes(bytes[offset..offset+2].try_into().unwrap())}
fn u32_at(bytes:&[u8],offset:usize)->u32 {u32::from_le_bytes(bytes[offset..offset+4].try_into().unwrap())}
fn id(bytes:&[u8],offset:usize,len:usize)->FileId {
    let mut value=[0;16];value[..len].copy_from_slice(&bytes[offset..offset+len]);FileId(value)
}
/// Both ENUM_USN_DATA and READ_USN_JOURNAL prefix records with an eight-byte continuation value.
pub fn parse(bytes:&[u8])->Result<(u64,Vec<Record>),String> {
    if bytes.len()<8||bytes.len()>super::MAX_FRAME_BYTES {return Err("Invalid NTFS batch size.".into())}
    let next=u64::from_le_bytes(bytes[..8].try_into().unwrap());
    let mut records=Vec::new();let mut offset=8;
    while offset<bytes.len() {
        if bytes.len()-offset<8 {return Err("Truncated NTFS record header.".into())}
        let length=u32_at(bytes,offset) as usize;
        if length<8||length>bytes.len()-offset||length%8!=0 {return Err("Invalid NTFS record length.".into())}
        let record=&bytes[offset..offset+length];
        let major=u16_at(record,4);
        let (minimum,id_len,parent_offset,usn_offset,reason_offset,attr_offset,name_offset)=match major {
            2=>(60,8,16,24,40,52,56),3=>(76,16,24,40,56,68,72),
            _=>return Err(format!("Unsupported NTFS record version {major}; reconciliation required.")),
        };
        if length<minimum {return Err("Truncated NTFS record.".into())}
        let name_length=u16_at(record,name_offset) as usize;
        let name_start=u16_at(record,name_offset+2) as usize;
        if name_length==0||name_length%2!=0||name_start<minimum||name_start%2!=0
            ||name_start.checked_add(name_length).is_none_or(|end|end>length) {
            return Err("Invalid NTFS filename range.".into())
        }
        let wide:Vec<u16>=record[name_start..name_start+name_length].chunks_exact(2)
            .map(|x|u16::from_le_bytes([x[0],x[1]])).collect();
        let name=String::from_utf16(&wide).map_err(|_|"Invalid NTFS filename encoding.")?;
        if name.contains(['\0','\\','/']) {return Err("Invalid NTFS filename component.".into())}
        records.push(Record{id:id(record,8,id_len),parent:id(record,parent_offset,id_len),
            usn:i64::from_le_bytes(record[usn_offset..usn_offset+8].try_into().unwrap()),
            reason:u32_at(record,reason_offset),attributes:u32_at(record,attr_offset),name});
        offset+=length;
    }
    Ok((next,records))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn batch(major:u16,name:&str)->Vec<u8>{
        let base=if major==2{60}else{76};
        let chars:Vec<u8>=name.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let length=(base+chars.len()+7)&!7;
        let mut data=vec![0u8;8+length];
        data[..8].copy_from_slice(&900u64.to_le_bytes());
        let r=&mut data[8..];r[..4].copy_from_slice(&(length as u32).to_le_bytes());
        r[4..6].copy_from_slice(&major.to_le_bytes());r[8..16].copy_from_slice(&42u64.to_le_bytes());
        let parent=if major==2{16}else{24};r[parent..parent+8].copy_from_slice(&5u64.to_le_bytes());
        let attr=if major==2{52}else{68};let n=attr+4;
        r[n..n+2].copy_from_slice(&(chars.len() as u16).to_le_bytes());
        r[n+2..n+4].copy_from_slice(&(base as u16).to_le_bytes());r[base..base+chars.len()].copy_from_slice(&chars);
        data
    }
    #[test]
    fn unicode_and_full_file_id_versions(){
        for major in [2,3] {let (next,records)=parse(&batch(major,"写真 Éditeur.exe")).unwrap();
            assert_eq!(next,900);assert_eq!(records.len(),1);assert!(records[0].executable());
            assert_eq!(records[0].name,"写真 Éditeur.exe");
            assert_ne!(records[0].id,records[0].parent);
        }
        let mut data=batch(3,"test.exe");data[8+23]=7;
        assert_eq!(parse(&data).unwrap().1[0].id.0[15],7,"128-bit identities must not truncate");
    }
    #[test]
    fn malformed_records_never_escape_bounds(){
        assert!(parse(&[]).is_err());let data=batch(2,"test.exe");
        for length in 0..data.len() {let _=parse(&data[..length]);}
        for (position,value) in [(8,255),(12,4),(8+56,255),(8+58,1)] {
            let mut invalid=data.clone();invalid[position]=value;assert!(parse(&invalid).is_err());
        }
        assert!(parse(&batch(2,"../evil.exe")).is_err());
        assert!(parse(&vec![0;super::super::MAX_FRAME_BYTES+1]).is_err());
    }
}
