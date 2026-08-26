// A type mismatch: bigint money bound where the schema wants text, and read as i32.
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    let r = sqlx::query!(
        r#"SELECT limit_minor FROM credit_lines WHERE tenant_id=$1 AND company_id=$2"#,
        "t1", 42i64).fetch_one(&pool).await?;      // company_id is text, 42i64 is not
    let l: i32 = r.limit_minor;                     // limit_minor is bigint -> i64
    println!("{l}");
    Ok(())
}
