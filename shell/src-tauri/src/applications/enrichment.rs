//! Descriptive data only. Online sources never supply launch targets, explicit aliases or executable arguments.
use super::Record;
use serde::{Deserialize,Serialize};
use serde_json::Value;
use std::{collections::BTreeSet,io::Read,net::{IpAddr,ToSocketAddrs},time::Duration};
use url::Url;
pub const EXTRACTOR_VERSION:u32=1;
const MAX_RESPONSE:u64=262_144;

#[derive(Clone,Debug,Serialize,Deserialize)]
#[serde(default,rename_all="camelCase")]
pub struct Options {pub enabled:bool,pub publisher_pages:bool}
impl Default for Options {fn default()->Self{Self{enabled:false,publisher_pages:true}}}
#[derive(Clone,Debug,Serialize,Deserialize)]
#[serde(rename_all="camelCase")]
pub struct Package {pub id:String,pub version:String}
#[derive(Clone,Debug,Default,Serialize,Deserialize)]
#[serde(default,rename_all="camelCase")]
pub struct Description {
    pub package_id:String,pub package_version:String,pub name:String,pub publisher:String,
    pub description:String,pub tags:Vec<String>,pub source:String,pub url:String,pub product_url:String,
    pub fetched:u64,pub extractor_version:u32,
}
pub fn product_key(name:&str)->String{
    name.chars().filter(|c|c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}
pub fn publisher_key(publisher:&str)->String{
    let normalized=super::rank::normalized(publisher);
    let mut words=normalized.split(|c:char|!c.is_alphanumeric()).filter(|s|!s.is_empty()).collect::<Vec<_>>();
    while words.last().is_some_and(|w|["inc","incorporated","corp","corporation","llc","ltd","limited","gmbh"].contains(w)){words.pop();}
    product_key(&words.join(" "))
}
fn comparable_name(name:&str,publisher:&str)->String{
    let name=product_key(name);
    let publisher=publisher_key(publisher);
    if publisher.len()>=4&&name.starts_with(&publisher)&&name.len()>publisher.len()+2{name[publisher.len()..].to_string()}else{name}
}
pub fn matches(record:&Record,description:&Description)->bool{
    let publisher=publisher_key(&record.publisher);
    if publisher.len()<3||publisher!=publisher_key(&description.publisher){return false}
    let name=comparable_name(&description.name,&description.publisher);
    !name.is_empty()&&[&record.product,&record.name].into_iter().any(|n|comparable_name(n,&record.publisher)==name)
}
pub fn valid_package(id:&str,version:&str)->bool{
    id.len()<=128&&id.contains('.')&&id.split('.').all(|part|!part.is_empty()&&part.bytes().all(|b|b.is_ascii_alphanumeric()||matches!(b,b'-'|b'_')))
        &&!version.is_empty()&&version.len()<=96&&version.bytes().all(|b|b.is_ascii_alphanumeric()||matches!(b,b'.'|b'-'|b'_'|b'+'))
        &&version.bytes().any(|b|b.is_ascii_alphanumeric())&&!version.eq_ignore_ascii_case("unknown")
}
pub fn parse_export(bytes:&[u8])->Result<Vec<Package>,String>{
    if bytes.len()>4_194_304{return Err("WinGet inventory is too large.".into())}
    let bytes=bytes.strip_prefix(&[0xef,0xbb,0xbf]).unwrap_or(bytes);
    let value:Value=serde_json::from_slice(bytes).map_err(|_|"WinGet did not return its documented JSON export.")?;
    let mut result=vec![];let mut seen=BTreeSet::new();
    for source in value["Sources"].as_array().ok_or("WinGet inventory has no sources.")? {
        let details=&source["SourceDetails"];
        if details["Identifier"]!="Microsoft.Winget.Source_8wekyb3d8bbwe"
            ||details["Argument"]!="https://cdn.winget.microsoft.com/cache"{continue}
        for row in source["Packages"].as_array().ok_or("Invalid WinGet package inventory.")?{
            let Some(id)=row["PackageIdentifier"].as_str()else{continue};
            let version=row["Version"].as_str().or_else(||row["PackageVersion"].as_str()).unwrap_or("");
            if valid_package(id,version)&&seen.insert((id.to_string(),version.to_string())){
                if result.len()>=5000{return Err("WinGet inventory exceeds the enrichment limit.".into())}
                result.push(Package{id:id.into(),version:version.into()});
            }
        }
    }
    Ok(result)
}
fn clean(text:&str,limit:usize)->String{
    text.chars().filter(|c|!c.is_control()||c.is_whitespace()).collect::<String>()
        .split_whitespace().collect::<Vec<_>>().join(" ").chars().take(limit).collect()
}
pub fn yaml(text:&str)->Result<yaml_rust2::Yaml,String>{
    use yaml_rust2::scanner::{Scanner,TokenType};
    if text.len()>MAX_RESPONSE as usize||text.contains('\0'){return Err("Invalid app manifest size.".into())}
    let mut tokens=0;let mut depth=0i32;
    for token in Scanner::new(text.chars()){
        tokens+=1;if tokens>10000{return Err("App manifest is too complex.".into())}
        match token.1{
            TokenType::Alias(..)|TokenType::Anchor(..)|TokenType::Tag(..)|TokenType::TagDirective(..)=>return Err("App manifest contains unsupported YAML references or tags.".into()),
            TokenType::BlockSequenceStart|TokenType::BlockMappingStart|TokenType::FlowSequenceStart|TokenType::FlowMappingStart=>{depth+=1;if depth>32{return Err("App manifest nesting is too deep.".into())}},
            TokenType::BlockEnd|TokenType::FlowSequenceEnd|TokenType::FlowMappingEnd=>depth-=1,
            _=>{},
        }
    }
    let mut docs=yaml_rust2::YamlLoader::load_from_str(text).map_err(|_|"Invalid structured app manifest.")?;
    if docs.len()!=1||docs[0].as_hash().is_none(){return Err("App manifest must be one mapping.".into())}
    Ok(docs.remove(0))
}
pub fn manifest(doc:&yaml_rust2::Yaml,package:&Package,url:&str)->Result<Description,String>{
    if doc["PackageIdentifier"].as_str()!=Some(package.id.as_str())||doc["PackageVersion"].as_str()!=Some(package.version.as_str()){
        return Err("App metadata identifies a different product or version.".into())
    }
    let name=clean(doc["PackageName"].as_str().unwrap_or(""),160);
    let publisher=clean(doc["Publisher"].as_str().unwrap_or(""),160);
    if name.is_empty()||publisher.is_empty(){return Err("App metadata is missing its product identity.".into())}
    let text=doc["Description"].as_str().filter(|s|s.trim().len()>=12)
        .or_else(||doc["ShortDescription"].as_str()).unwrap_or("");
    let tags=doc["Tags"].as_vec().into_iter().flatten().filter_map(|v|v.as_str())
        .take(32).map(|s|clean(s,80)).filter(|s|!s.is_empty()).collect();
    Ok(Description{package_id:package.id.clone(),package_version:package.version.clone(),name,publisher,
        description:clean(text,1024),tags,source:"WinGet".into(),url:url.into(),
        product_url:doc["PackageUrl"].as_str().map(|s|s.chars().take(2048).collect()).unwrap_or_default(),
        fetched:now(),extractor_version:EXTRACTOR_VERSION})
}
pub fn public_url(text:&str)->Result<Url,String>{
    let url=Url::parse(text).map_err(|_|"Invalid description source URL.")?;
    if text.len()>4096||url.scheme()!="https"||!url.username().is_empty()||url.password().is_some()
        ||url.port_or_known_default()!=Some(443)||url.fragment().is_some(){return Err("Description sources require a public HTTPS URL.".into())}
    let host=url.host_str().ok_or("Description source has no hostname.")?;
    if !host.contains('.')||host.eq_ignore_ascii_case("localhost")||host.ends_with(".local")||host.ends_with(".localhost")
        ||host.ends_with(".internal")||host.ends_with(".lan"){return Err("Local description sources are not supported.".into())}
    if let Ok(ip)=host.parse::<IpAddr>(){if !public_ip(ip){return Err("Private description sources are not supported.".into())}}
    Ok(url)
}
fn public_ip(ip:IpAddr)->bool{
    match ip{
        IpAddr::V4(ip)=>{let b=ip.octets();!ip.is_private()&&!ip.is_loopback()&&!ip.is_link_local()
            &&!ip.is_broadcast()&&!ip.is_documentation()&&!ip.is_unspecified()&&!ip.is_multicast()
            &&b[0]!=0&&b[0]<224&&!(b[0]==100&&(64..128).contains(&b[1]))&&!(b[0]==198&&(b[1]==18||b[1]==19))},
        IpAddr::V6(ip)=>{if let Some(ip)=ip.to_ipv4_mapped(){return public_ip(IpAddr::V4(ip))}
            let b=ip.octets();b[0]&0xe0==0x20&&!(b[0..4]==[0x20,0x01,0x0d,0xb8])},
    }
}
pub fn fetch(text:&str)->Result<(String,String),String>{
    let mut url=public_url(text)?;let original=url.host_str().unwrap().to_string();
    for _ in 0..=2 {
        let host=url.host_str().unwrap().to_string();
        if host!=original&&host!=format!("www.{original}")&&original!=format!("www.{host}"){return Err("Publisher redirected to another site.".into())}
        let addresses=(host.as_str(),443).to_socket_addrs().map_err(|_|"Description source DNS is unavailable.")?
            .filter(|address|public_ip(address.ip())).collect::<Vec<_>>();
        if addresses.is_empty(){return Err("Description source has no public address.".into())}
        let client=reqwest::blocking::Client::builder().redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5)).timeout(Duration::from_secs(15))
            .resolve_to_addrs(&host,&addresses).user_agent("DigUp app metadata/1").build().map_err(|e|e.to_string())?;
        let response=client.get(url.clone()).send().map_err(|_|"Description source could not be reached securely.")?;
        if response.status().is_redirection(){
            let location=response.headers().get(reqwest::header::LOCATION).and_then(|h|h.to_str().ok()).ok_or("Invalid publisher redirect.")?;
            url=public_url(url.join(location).map_err(|_|"Invalid publisher redirect.")?.as_str())?;continue;
        }
        if !response.status().is_success(){return Err(format!("Description source returned HTTP {}.",response.status().as_u16()))}
        let mut bytes=vec![];response.take(MAX_RESPONSE+1).read_to_end(&mut bytes).map_err(|_|"Description download stopped.")?;
        if bytes.len()>MAX_RESPONSE as usize{return Err("Description source is too large.".into())}
        let text=String::from_utf8(bytes).map_err(|_|"Description source is not UTF-8.")?;
        return Ok((text,url.to_string()))
    }
    Err("Description source redirected too many times.".into())
}
pub fn fetch_package(package:&Package,publisher_pages:bool)->Result<Description,String>{
    if !valid_package(&package.id,&package.version){return Err("Invalid product identity.".into())}
    let mut base=Url::parse("https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/").unwrap();
    {let mut segments=base.path_segments_mut().map_err(|_|"Invalid manifest base.")?;
        segments.pop_if_empty().push(&package.id[..1].to_ascii_lowercase());
        for part in package.id.split('.'){segments.push(part);}segments.push(&package.version);}
    let first=format!("{}/{}.yaml",base.as_str().trim_end_matches('/'),package.id);
    let (text,mut source)=fetch(&first)?;let mut doc=yaml(&text)?;
    if let Some(locale)=doc["DefaultLocale"].as_str(){
        if locale.len()>32||!locale.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'-'){return Err("Invalid manifest locale.".into())}
        let locale_url=format!("{}/{}.locale.{}.yaml",base.as_str().trim_end_matches('/'),package.id,locale);
        let(text,url)=fetch(&locale_url)?;doc=yaml(&text)?;source=url;
    }
    let mut result=manifest(&doc,package,&source)?;
    if result.description.chars().count()<40&&publisher_pages&&!result.product_url.is_empty(){
        if let Ok((html,url))=fetch(&result.product_url){
            if let Some(text)=publisher_description(&html){
                result.description=text;result.source="Publisher".into();result.url=url;
            }
        }
    }
    if result.description.len()<12{return Err("No useful product description was available.".into())}
    Ok(result)
}
pub fn publisher_description(html:&str)->Option<String>{
    if html.len()>MAX_RESPONSE as usize{return None}
    let document=dom_query::Document::from(html);
    for selector in [r#"meta[property="og:description"]"#,r#"meta[name="description"]"#]{
        if let Some(value)=document.select(selector).first().attr("content"){
            let text=clean(value.as_ref(),1024);if text.len()>=12{return Some(text)}
        }
    }
    None
}
pub fn now()->u64{std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()}

#[cfg(test)]mod tests{
    use super::*;
    #[test]fn identities_are_verified_in_structured_metadata(){
        let p=Package{id:"Example.Editor".into(),version:"1.2.3".into()};
        let y=yaml("PackageIdentifier: Example.Editor\nPackageVersion: 1.2.3\nPackageName: Photo Editor\nPublisher: Example Inc.\nShortDescription: Edit photographs and retouch portraits\nTags: [photos, portraits]\n").unwrap();
        let d=manifest(&y,&p,"https://example.com/source").unwrap();
        let mut r=Record::new("x".into(),"Photo Editor".into(),"fixture",super::super::Target::Shell{parsing_name:"fixture".into()});
        r.publisher="Example Incorporated".into();assert!(matches(&r,&d));
        r.name="Photo Editor Pro".into();assert!(!matches(&r,&d));
        r.name="Photo Editor".into();r.publisher="Another publisher".into();assert!(!matches(&r,&d));
        assert!(manifest(&y,&Package{id:p.id,version:"2".into()},"https://example.com").is_err());
    }
    #[test]fn parser_rejects_alias_bombs_and_unbounded_documents(){
        assert!(yaml("a: &a [1,2]\nb: *a\n").is_err());
        assert!(yaml("---\na: 1\n---\nb: 2\n").is_err());
        assert!(yaml(&"x".repeat(262145)).is_err());
    }
    #[test]fn local_sources_and_untrusted_inventory_are_rejected(){
        for url in ["http://example.com","https://localhost/a","https://127.0.0.1/a","https://192.168.1.1/a","https://user:pass@example.com","file:///C:/secret","https://[::1]/"]{assert!(public_url(url).is_err(),"{url}")}
        assert!(public_url("https://example.com/product").is_ok());
        let export=serde_json::json!({"Sources":[{"SourceDetails":{"Identifier":"custom","Argument":"https://example.com"},"Packages":[{"PackageIdentifier":"Example.Editor","Version":"1.2.3"}]}]});
        assert!(parse_export(&serde_json::to_vec(&export).unwrap()).unwrap().is_empty());
        assert!(!valid_package("Example.Editor/../run","1"));
    }
    #[test]fn publisher_html_is_data_and_decodes_entities(){
        let html=r#"<html><head><meta name="description" content="Edit photos &amp; retouch portraits."></head><script>throw new Error('must not execute')</script></html>"#;
        assert_eq!(publisher_description(html).as_deref(),Some("Edit photos & retouch portraits."));
    }
}
