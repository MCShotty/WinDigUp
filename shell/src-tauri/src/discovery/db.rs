//! Small SQLite boundary. Each connection stays with one serial owner; readers never run migrations.
use std::{ffi::{CStr,CString},marker::PhantomData,os::raw::{c_char,c_int,c_void},path::Path,rc::Rc};
type Destructor=Option<unsafe extern "C" fn(*mut c_void)>;
#[cfg_attr(windows,link(name="winsqlite3"))]
#[cfg_attr(not(windows),link(name="sqlite3"))]
unsafe extern "C" {
    fn sqlite3_open_v2(file:*const c_char,db:*mut *mut c_void,flags:c_int,vfs:*const c_char)->c_int;
    fn sqlite3_close_v2(db:*mut c_void)->c_int;
    fn sqlite3_errmsg(db:*mut c_void)->*const c_char;
    fn sqlite3_busy_timeout(db:*mut c_void,ms:c_int)->c_int;
    fn sqlite3_prepare_v2(db:*mut c_void,sql:*const c_char,n:c_int,stmt:*mut *mut c_void,tail:*mut *const c_char)->c_int;
    fn sqlite3_finalize(stmt:*mut c_void)->c_int;
    fn sqlite3_bind_text(stmt:*mut c_void,index:c_int,text:*const c_char,len:c_int,destructor:Destructor)->c_int;
    fn sqlite3_bind_int64(stmt:*mut c_void,index:c_int,value:i64)->c_int;
    fn sqlite3_bind_null(stmt:*mut c_void,index:c_int)->c_int;
    fn sqlite3_step(stmt:*mut c_void)->c_int;
    fn sqlite3_column_count(stmt:*mut c_void)->c_int;
    fn sqlite3_column_text(stmt:*mut c_void,index:c_int)->*const u8;
    fn sqlite3_column_bytes(stmt:*mut c_void,index:c_int)->c_int;
}
pub enum Value<'a> {Text(&'a str),Integer(i64),Null}
pub struct Database {handle:*mut c_void,_owner:PhantomData<Rc<()>>}
struct Statement(*mut c_void);
impl Drop for Statement {fn drop(&mut self){unsafe{sqlite3_finalize(self.0);}}}
impl Drop for Database {fn drop(&mut self){unsafe{sqlite3_close_v2(self.handle);}}}
impl Database {
    pub fn open(path:&Path,read_only:bool)->Result<Self,String> {
        let file=CString::new(path.to_string_lossy().as_bytes()).map_err(|_|"Invalid database path.")?;
        let mut handle=std::ptr::null_mut();
        let result=unsafe{sqlite3_open_v2(file.as_ptr(),&mut handle,if read_only{1}else{2|4},std::ptr::null())};
        if result!=0 {
            let error=if handle.is_null(){"Cannot open discovery database.".into()}else{
                let error=unsafe{CStr::from_ptr(sqlite3_errmsg(handle))}.to_string_lossy().into_owned();
                unsafe{sqlite3_close_v2(handle)};error};
            return Err(error)
        }
        unsafe{sqlite3_busy_timeout(handle,250);}
        Ok(Self{handle,_owner:PhantomData})
    }
    fn error(&self)->String {unsafe{CStr::from_ptr(sqlite3_errmsg(self.handle))}.to_string_lossy().into_owned()}
    fn prepare(&self,sql:&str,values:&[Value<'_>])->Result<Statement,String> {
        let sql=CString::new(sql).map_err(|_|"Invalid SQL statement.")?;
        let mut stmt=std::ptr::null_mut();
        let result=unsafe{sqlite3_prepare_v2(self.handle,sql.as_ptr(),-1,&mut stmt,std::ptr::null_mut())};
        if result!=0{return Err(self.error())}
        let statement=Statement(stmt);
        for (i,value)in values.iter().enumerate() {
            let result=unsafe{match value {
                Value::Text(text)=>{
                    let length:i32=text.len().try_into().map_err(|_|"Discovery value is too large.")?;
                    let transient:Destructor=std::mem::transmute(-1isize);
                    sqlite3_bind_text(stmt,(i+1)as i32,text.as_ptr().cast(),length,transient)
                },
                Value::Integer(value)=>sqlite3_bind_int64(stmt,(i+1)as i32,*value),
                Value::Null=>sqlite3_bind_null(stmt,(i+1)as i32),
            }};
            if result!=0{return Err(self.error())}
        }
        Ok(statement)
    }
    pub fn run(&self,sql:&str,values:&[Value<'_>])->Result<(),String> {
        let statement=self.prepare(sql,values)?;
        let result=unsafe{sqlite3_step(statement.0)};
        if result==101||result==100 {Ok(())}else{Err(self.error())}
    }
    pub fn rows(&self,sql:&str,values:&[Value<'_>])->Result<Vec<Vec<String>>,String> {
        let mut rows=vec![];
        self.each(sql,values,|row|{rows.push(row);Ok(())})?;
        Ok(rows)
    }
    pub fn each(&self,sql:&str,values:&[Value<'_>],mut row:impl FnMut(Vec<String>)->Result<(),String>)->Result<(),String> {
        let statement=self.prepare(sql,values)?;
        loop {
            let code=unsafe{sqlite3_step(statement.0)};
            if code==101{return Ok(())}
            if code!=100{return Err(self.error())}
            let count=unsafe{sqlite3_column_count(statement.0)};
            let mut values=Vec::with_capacity(count as usize);
            for col in 0..count {
                let text=unsafe{sqlite3_column_text(statement.0,col)};
                let length=unsafe{sqlite3_column_bytes(statement.0,col)};
                values.push(if text.is_null(){String::new()}else{
                    String::from_utf8_lossy(unsafe{std::slice::from_raw_parts(text,length as usize)}).into_owned()});
            }
            row(values)?
        }
    }
}
#[cfg(test)]mod tests {
    use super::*;
    #[test]fn parameters_unicode_and_readers_are_independent() {
        let file=std::env::temp_dir().join(format!("digup-discovery-{}-{}.sqlite",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        {
            let db=Database::open(&file,false).unwrap();
            db.run("CREATE TABLE test(value TEXT)",&[]).unwrap();
            db.run("INSERT INTO test VALUES(?)",&[Value::Text("写真'; DROP TABLE test;--")]).unwrap();
            let read=Database::open(&file,true).unwrap();
            assert_eq!(read.rows("SELECT value FROM test",&[]).unwrap()[0][0],"写真'; DROP TABLE test;--");
            assert!(read.run("DELETE FROM test",&[]).is_err());
        }
        std::fs::remove_file(file).unwrap();
    }
}
