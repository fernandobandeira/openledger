// query! macro, posted_minor dropped from the SELECT list, field still read.
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    let r = sqlx::query!(
        r#"SELECT cl.limit_minor,
                  COALESCE((SELECT SUM(held_minor) FROM card_hold_groups
                             WHERE tenant_id=cl.tenant_id AND company_id=cl.company_id),0)::bigint AS "held_minor!"
             FROM credit_lines cl WHERE cl.tenant_id=$1 AND cl.company_id=$2"#,
        "t1", "bugco").fetch_one(&pool).await?;
    let available = r.limit_minor - r.posted_minor - r.held_minor;
    println!("{available}");
    Ok(())
}
