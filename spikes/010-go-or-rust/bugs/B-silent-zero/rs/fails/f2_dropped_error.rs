// Trying to spell Go's `posted, _ := ...` in Rust.
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    let posted: i64 = sqlx::query_scalar!(
        r#"SELECT balance_after FROM ledger_entries
            WHERE tenant_id=$1 AND account_id=$2 ORDER BY account_seq DESC LIMIT 1"#,
        "t1", uuid::Uuid::nil()).fetch_one(&pool).await;   // no `?`, no unwrap
    println!("{posted}");
    Ok(())
}
