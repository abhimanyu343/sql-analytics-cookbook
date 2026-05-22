# 🗄️ SQL Analytics Cookbook

> Advanced SQL patterns for real-world business analytics — written for analysts and engineers who already know SELECT and want to think in sets, not loops.

![SQL](https://img.shields.io/badge/SQL-PostgreSQL%2014+-336791?logo=postgresql&logoColor=white)
![Difficulty](https://img.shields.io/badge/Level-Intermediate%20→%20Advanced-orange)

---

## 📖 What's Inside

Each file is self-contained: schema → sample data → progressively complex queries → annotated explanations.
Every query runs on **PostgreSQL 14+** (most work on SQLite/MySQL with minor tweaks noted inline).

| Module | Topics | Key Concepts |
|--------|--------|--------------|
| `01_window_functions.sql` | Rankings, running totals, moving averages | ROW_NUMBER, RANK, DENSE_RANK, LAG/LEAD, NTILE |
| `02_cohort_retention.sql` | User retention, cohort heatmaps | DATE_TRUNC, CASE pivoting, self-joins |
| `03_funnel_analysis.sql` | Conversion funnels, drop-off rates | Conditional aggregation, ordered steps |
| `04_revenue_metrics.sql` | MRR, ARR, churn, LTV, expansion | SaaS metrics, cumulative sums |
| `05_time_series_sql.sql` | Gap filling, YoY, rolling stats | GENERATE_SERIES, LAG, FILTER |
| `06_advanced_ctes.sql` | Recursive CTEs, graph traversal, deduplication | WITH RECURSIVE, LATERAL |
| `07_query_optimisation.sql` | Indexes, EXPLAIN, partitioning | EXPLAIN ANALYZE, partial indexes |
| `08_python_sql_integration.py` | SQLAlchemy ORM + raw SQL, connection pooling | psycopg2, pandas.read_sql |

---

## 🧠 Design Philosophy

These queries are written the way senior analysts actually write SQL in production:
- **CTEs over subqueries** — readable, debuggable, reusable
- **Window functions over GROUP BY + JOIN** — cleaner, faster
- **Explicit column lists** — never `SELECT *` in production
- **Comments on the WHY** — not just what the code does

---

## 🚀 Quick Start

```bash
# Clone and load sample data
git clone https://github.com/abhimanyu343/sql-analytics-cookbook
cd sql-analytics-cookbook

# PostgreSQL
psql -U postgres -f schema/create_tables.sql
psql -U postgres -f schema/sample_data.sql

# Then open any .sql file and run section by section
```

---
*[LinkedIn](https://linkedin.com/in/abhimanyusarda343) · Built from real analytics work at EXL Service and GPIL*
