# Data Contract: `processed/customers`

This document is the agreement between the team that produces the
`processed/customers/` dataset and the teams that consume it. It states the
schema, the quality guarantees the producer enforces, the service level the
consumer may rely on, and how the dataset is allowed to change.

Produced by the Lab 2 data pipeline (`raw/` → `processed/` → `features/`).
The figures in *Observed* columns come from the Lab 2 run recorded in
`docs/lab2-verify-output.txt`.

## Producer

- **Team / process:** Glue ETL job `northstar-dev-transform`
  (`glue-scripts/transform.py`), running as IAM role `northstar-dev-DataEngineer`.
- **Source:** the crawler-registered catalog table `northstar_dev.customers`
  over `s3://northstar-dev-data-345594594463/raw/customers/`.
- **Sink:** `s3://northstar-dev-data-345594594463/processed/customers/` (Parquet).

## Consumers

- Glue ETL job `northstar-dev-feature-engineer` — reads every row to build the
  customer-level feature set.
- (Future, Lab 3) model training and direct Athena queries over the processed
  Parquet from the analyst's own credentials.

## Grain

**One row per transaction.** A customer appears on many rows; this is expected
and is a requirement, not a defect. The feature engineering job relies on the
per-customer purchase history to compute its aggregates. Nothing in this
dataset is deduplicated by `customer_id`.

Observed: 157,627 rows across 9,999 distinct `customer_id` values
(~15.8 rows/customer), which satisfies `rows > distinct customers`.

## Schema

| Column | Type | Nullable | Description |
| --- | --- | --- | --- |
| `transaction_id` | string | No | Natural key of the purchase. Format `TXN-{12 alphanumeric}`. Unique across the dataset; the dedup key. |
| `customer_id` | string | No | Customer key, format `CUST-{8 digits}`. Repeats by design (one per purchase). The join key for every downstream feature. |
| `purchase_date` | date (ISO 8601 `yyyy-MM-dd`) | No | Date of purchase. Source rows were ISO 8601 or `MM/dd/yyyy`; both are parsed and normalized to ISO 8601. |
| `order_value` | double | No | Gross order value in USD. Null source values are median-imputed. |
| `num_items` | integer | No | Number of line items in the order. Null source values are median-imputed (rounded to an integer). |
| `payment_method` | string | No | One of `credit_card`, `debit_card`, `gift_card`, `cash`. Nulls imputed as `unknown`. |
| `channel` | string | No | One of `online`, `store`. Nulls imputed as `unknown`. |
| `store_id` | string | No | `STORE-{3 digits}` for in-store orders, or `ONLINE`. Nulls imputed as `unknown`. |
| `product_category` | string | No | Primary category of the order. One of `Apparel`, `Beauty`, `Electronics`, `Footwear`, `Grocery`, `Home`, `Outdoor`, `Toys`; `unknown` marks an imputed missing value. |

All string columns are trimmed and contain no leading/trailing whitespace.

## Quality Guarantees

The producer enforces these before writing; a violation fails the job rather
than shipping a bad dataset (assertions in `glue-scripts/transform.py`).

1. **`customer_id` is never null and never an empty string.** Observed: 0 nulls.
   A row without it cannot be attributed to a customer and is dropped.
2. **`transaction_id` is unique.** 0 duplicate `transaction_id` values. A
   repeated `customer_id` is expected; a repeated `transaction_id` is an
   ingestion retry and is collapsed to exactly one row.
3. **`purchase_date` is a valid, fully parsed ISO 8601 date.** 0 nulls after
   parsing, and every value falls within the source range
   `2025-04-01` to `2026-06-30`.
4. **`order_value` is non-null and bounded.** Observed range `$15.00`–`$620.00`
   (median `$141.75`); the contract requires `> 0` and `<= 10000`.
5. **`num_items` is a non-null integer in `[1, 9]`.** Observed `1`–`9`.
6. **Categorical columns hold only the enumerated values above.** Any other
   value (including a new category) is a breaking schema change; see Versioning.
7. **No duplicate composite of `(transaction_id)` and no partial writes.** The
   job writes with `mode("overwrite")` only after all assertions pass, so a
   failed run leaves the previous dataset in place.

Note on the `features/customers/` consumer: `processed/customers/` guarantees
*transaction* grain. A consumer that requires one row per customer must
aggregate — it must not assume it.

## SLA

- **Freshness:** new data landing in `raw/customers/` is transformed and
  available in `processed/customers/` within **2 hours** of landing. The
  pipeline is currently triggered on demand (the crawler has no schedule, and
  the job is started explicitly), so the 2-hour bound applies once a run is
  triggered and the transform job completes in minutes.
- **Availability:** `processed/customers/` is a versioned S3 prefix; the latest
  complete run is always the current state of the prefix.
- **Completeness:** a run either publishes a complete dataset or fails without
  modifying the prefix.
- **Consumer support:** questions and incidents are raised against the
  `northstar-dev-transform` job definition in this repository.

## Versioning

- **Additive changes** (a new nullable column appended) are announced to
  consumers and may land in the current prefix once consumers confirm they
  ignore unknown columns.
- **Breaking changes** (removing a column, renaming, changing a type, changing
  the grain, or changing the meaning of a value) require a **new S3 prefix**,
  e.g. `processed/customers/v2/`. The existing prefix is never rewritten in
  place.
- **Notification:** breaking changes require **5 business days** advance notice
  to every consumer listed above, with the old prefix retained for at least one
  full pipeline cycle.
- **Contract changes** to this document are versioned in git alongside the
  producer code that implements them.
