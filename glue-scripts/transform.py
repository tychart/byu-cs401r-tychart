"""
Glue ETL: raw/customers/ -> processed/customers/

Reads the crawler-registered catalog table, enforces types, imputes nulls,
removes duplicate transactions, and writes Parquet to the processed zone.

Grain note: this job is transaction-level in and transaction-level out. One
row per purchase, many rows per customer. The feature engineering job is
what collapses to one row per customer. Deduplicating on customer_id here
would destroy the purchase history that RFM features are computed from.

Job arguments (wired by Terraform in modules/glue):
  --database_name  Glue catalog database
  --table_name     catalog table produced by the crawler
  --output_path    s3:// destination for Parquet output
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.window import Window

# Target types for the processed zone. The crawler infers everything from CSV
# as string, so every one of these is an explicit cast, not a no-op.
SCHEMA = {
    "transaction_id": "string",
    "customer_id": "string",
    "purchase_date": "date",
    "order_value": "double",
    "num_items": "int",
    "payment_method": "string",
    "channel": "string",
    "store_id": "string",
    "product_category": "string",
}

NUMERIC_COLS = ["order_value", "num_items"]
STRING_COLS = ["payment_method", "channel", "store_id", "product_category"]


def cast_types(df):
    """Cast every column to its SCHEMA type. Drop rows with no customer_id.

    Three things to handle, in this order:

    1. TRIM whitespace on every column first. A customer_id of
       "  CUST-10000001 " is not null, but it will not group or join
       correctly either, and the bug is invisible until your feature
       counts come out slightly wrong.
    2. Convert empty strings to real nulls. CSV gives you "" where you
       want None; Spark treats those as different things.
    3. Parse purchase_date. Most rows are ISO 8601 (yyyy-MM-dd) but a few
       percent are MM/dd/yyyy. F.to_date returns null on a format
       mismatch instead of raising, so parse both formats and coalesce.
       If you only parse the ISO form you will silently null out the
       other rows and then drop them.

    Finally, drop rows where customer_id is null. That column is the join
    key for every downstream feature, so a row without it cannot be
    attributed to anyone.
    """
    # 1. Trim every column. A customer_id of "  CUST-10000001 " is not null,
    #    but it will not group or join correctly either, and the bug stays
    #    invisible until your feature counts come out slightly wrong.
    for c in df.columns:
        df = df.withColumn(c, F.trim(F.col(c).cast("string")))

    # 2. Empty string -> real null. CSV gives us "" where we want None, and
    #    Spark treats the two as different values.
    for c in df.columns:
        df = df.withColumn(c, F.when(F.col(c) == "", None).otherwise(F.col(c)))

    # 3. Parse purchase_date from BOTH formats. to_date returns null on a
    #    mismatch instead of raising, so parsing only the ISO form would
    #    silently null out the ~3% MM/DD/YYYY rows (and then drop them).
    df = df.withColumn(
        "purchase_date",
        F.coalesce(
            F.to_date(F.col("purchase_date"), "yyyy-MM-dd"),
            F.to_date(F.col("purchase_date"), "MM/dd/yyyy"),
        ),
    )

    # 4. Cast to the SCHEMA types. Selecting explicitly also keeps the dataset
    #    to the published contract by dropping any crawler-injected extras.
    df = df.select(*[F.col(c).cast(t).alias(c) for c, t in SCHEMA.items()])

    # 5. customer_id is the join key for every downstream feature; a row
    #    without it cannot be attributed to anyone.
    return df.filter(F.col("customer_id").isNotNull())


def impute_nulls(df):
    """Numeric columns -> column median. String columns -> 'unknown'.

    Use the MEDIAN, not the mean. order_value is right-skewed: a handful
    of large orders drags a mean-imputed value well above the typical
    order and quietly inflates every monetary feature you compute later.

    DataFrame.approxQuantile(col, [0.5], 0.0) gives you an exact median.
    Remember num_items is an integer column - round before you fill it.

    Numeric columns: NUMERIC_COLS.  String columns: STRING_COLS.
    """
    # Numeric columns: the median. Use the MEDIAN, not the mean -
    # order_value is right-skewed, so a mean-imputed value sits above the
    # typical order and inflates every monetary feature computed later.
    dtypes = dict(df.dtypes)
    for c in NUMERIC_COLS:
        median = df.approxQuantile(c, [0.5], 0.0)[0]
        if median is None:
            continue
        # num_items is an integer column; filling it with 3.7 would widen the
        # schema to double and break the contract.
        if dtypes.get(c) in ("int", "bigint", "smallint", "tinyint"):
            median = int(round(median))
        df = df.fillna({c: median})

    # String columns: an explicit 'unknown' beats a null the next job has to
    # special-case.
    return df.fillna({c: "unknown" for c in STRING_COLS})


def deduplicate(df):
    """Keep one row per transaction_id.

    Deduplicate on transaction_id, NOT on customer_id. A customer is
    expected to have many transactions - that purchase history is exactly
    what the feature engineering job aggregates over in Task 3.
    Collapsing to one row per customer here makes total_lifetime_value
    and purchase_frequency_30d impossible to compute, and you will not
    discover it until Task 3 fails.

    Duplicates are ingestion artifacts: the same transaction landing twice
    from a retry. Break ties deterministically (for example by
    purchase_date descending, then order_value descending) so repeated
    runs produce the same output rather than depending on partition order.

    A window function with row_number() over a partition by transaction_id
    is the idiomatic approach.
    """
    # Partition by transaction_id and keep the first row. Deduplicating on
    # customer_id instead would collapse a customer's whole purchase history to
    # one row and make Task 3's RFM features impossible to compute.
    #
    # Ordering by purchase_date then order_value descending makes the choice
    # deterministic when the same transaction lands twice, so re-running the
    # job produces byte-identical output instead of depending on partition
    # order. nulls_last guards the (should not happen) unparsed-date case.
    window = Window.partitionBy("transaction_id").orderBy(
        F.col("purchase_date").desc_nulls_last(),
        F.col("order_value").desc_nulls_last(),
    )

    return (
        df.withColumn("_row_number", F.row_number().over(window))
        .filter(F.col("_row_number") == 1)
        .drop("_row_number")
    )


def main():
    args = getResolvedOptions(
        sys.argv, ["JOB_NAME", "database_name", "table_name", "output_path"]
    )

    sc = SparkContext()
    glue_context = GlueContext(sc)
    spark = glue_context.spark_session
    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    dyf = glue_context.create_dynamic_frame.from_catalog(
        database=args["database_name"],
        table_name=args["table_name"],
    )
    df = dyf.toDF()
    raw_count = df.count()
    print(f"[transform] read {raw_count} raw rows from "
          f"{args['database_name']}.{args['table_name']}")

    df = cast_types(df)
    after_cast = df.count()
    print(f"[transform] after cast_types: {after_cast} rows "
          f"({raw_count - after_cast} dropped for null customer_id)")

    df = impute_nulls(df)
    print(f"[transform] after impute_nulls: {df.count()} rows")

    df = deduplicate(df)
    final_count = df.count()
    print(f"[transform] after deduplicate: {final_count} rows "
          f"({after_cast - final_count} duplicate transactions removed)")

    # Fail loudly rather than writing a bad dataset the feature job will
    # silently consume. These are the same guarantees the data contract
    # published for processed/customers/, enforced at the producer.
    assert df.filter(F.col("customer_id").isNull()).count() == 0, \
        "null customer_id survived the transform"
    assert df.select("transaction_id").distinct().count() == final_count, \
        "duplicate transaction_id survived the transform"
    assert df.filter(F.col("purchase_date").isNull()).count() == 0, \
        "unparseable purchase_date survived the transform"

    (df.coalesce(4)
       .write
       .mode("overwrite")
       .parquet(args["output_path"]))
    print(f"[transform] wrote {final_count} rows to {args['output_path']}")

    job.commit()


if __name__ == "__main__":
    main()
