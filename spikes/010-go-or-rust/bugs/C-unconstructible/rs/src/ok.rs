mod posting; use posting::*;
fn main() {
    let p = Posting::new(uuid::Uuid::new_v4(), uuid::Uuid::new_v4(), Minor(100),
                         Currency::parse("USD").unwrap());
    println!("rs  Posting::new(...) -> {:?}", p.is_some());
}
