// the same shape as the real one, reduced to what the test needs
use uuid::Uuid;
#[derive(Debug, Clone, Copy, PartialEq, Eq)] pub struct Minor(pub i64);
#[derive(Debug, Clone, Copy, PartialEq, Eq)] pub struct Currency([u8;3]);
impl Currency { pub fn parse(s:&str)->Option<Self>{ let b=s.as_bytes();
    if b.len()==3 && b.iter().all(|c|c.is_ascii_uppercase()) {Some(Currency([b[0],b[1],b[2]]))} else {None} } }
#[derive(Debug, Clone, Copy)]
pub struct Posting { source: Uuid, destination: Uuid, amount: Minor, currency: Currency }
impl Posting {
    pub fn new(source: Uuid, destination: Uuid, amount: Minor, currency: Currency) -> Option<Self> {
        if amount.0 <= 0 || source == destination { return None }
        Some(Posting { source, destination, amount, currency })
    }
}
