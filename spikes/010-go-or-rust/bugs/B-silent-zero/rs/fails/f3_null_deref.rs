// Using a nullable money column as if it were a number.
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    let raw = sqlx::query_scalar!(
        r#"SELECT raw_amount FROM card_auth_events WHERE tenant_id=$1 AND raw_amount IS NULL LIMIT 1"#,
        "t1").fetch_one(&pool).await?;
    let total: i64 = raw + 100;   // raw is Option<i64>
    println!("{total}");
    Ok(())
}
