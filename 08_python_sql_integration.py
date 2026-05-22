"""
MODULE 08: Python + SQL Integration
SQLAlchemy ORM, connection pooling, pandas integration, query builders.
Real patterns from production analytics engineering.
"""

import os
import logging
from contextlib import contextmanager
from typing import Iterator, Optional, List, Dict, Any

import pandas as pd
import numpy as np
from sqlalchemy import (
    create_engine, text, MetaData, Table, Column,
    Integer, String, Numeric, DateTime, Boolean, ForeignKey,
    Index, event
)
from sqlalchemy.pool import QueuePool
from sqlalchemy.orm import Session, sessionmaker, DeclarativeBase
from sqlalchemy.dialects.postgresql import insert as pg_insert

log = logging.getLogger(__name__)


# ── 1. Engine with production-grade connection pooling ────────────────────────

def create_analytics_engine(
    database_url: str = None,
    pool_size: int = 5,
    max_overflow: int = 10,
    pool_timeout: int = 30,
    pool_recycle: int = 1800,      # Recycle connections after 30 min
    echo: bool = False,
) -> "Engine":
    """
    Create a SQLAlchemy engine with production-grade pooling settings.

    Args:
        database_url: PostgreSQL connection string. Falls back to DATABASE_URL env var.
        pool_size:    Number of connections maintained in pool
        max_overflow: Extra connections allowed beyond pool_size
        pool_timeout: Seconds to wait for connection from pool
        pool_recycle: Recycle connections older than this (avoids stale connections)
        echo:         Log all SQL statements (set True for debugging)
    """
    url = database_url or os.getenv(
        "DATABASE_URL",
        "postgresql://postgres:postgres@localhost:5432/analytics"
    )
    engine = create_engine(
        url,
        poolclass=QueuePool,
        pool_size=pool_size,
        max_overflow=max_overflow,
        pool_timeout=pool_timeout,
        pool_recycle=pool_recycle,
        echo=echo,
        # Return dict-like rows (not tuples)
        execution_options={"stream_results": True}
    )

    # Log slow queries (>500ms) to help optimise
    @event.listens_for(engine, "before_cursor_execute")
    def before_execute(conn, cursor, statement, parameters, context, executemany):
        conn.info.setdefault("query_start_time", []).append(pd.Timestamp.now())

    @event.listens_for(engine, "after_cursor_execute")
    def after_execute(conn, cursor, statement, parameters, context, executemany):
        total = pd.Timestamp.now() - conn.info["query_start_time"].pop(-1)
        if total.total_seconds() > 0.5:
            log.warning(f"Slow query ({total.total_seconds():.2f}s): {statement[:120]}")

    log.info(f"Engine created: pool_size={pool_size}, max_overflow={max_overflow}")
    return engine


# ── 2. Session context manager (handles commit/rollback automatically) ─────────

@contextmanager
def get_session(engine) -> Iterator[Session]:
    """
    Context manager that yields a SQLAlchemy session.
    Auto-commits on success, rolls back on exception.

    Usage:
        with get_session(engine) as session:
            session.execute(text("INSERT INTO ..."))
            # Automatically committed on exit, rolled back on exception
    """
    SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)
    session = SessionLocal()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


# ── 3. Analytics query functions ───────────────────────────────────────────────

class AnalyticsDB:
    """
    High-level analytics query interface.
    All methods return pandas DataFrames for immediate analysis.
    """

    def __init__(self, engine):
        self.engine = engine

    def get_cohort_retention(
        self,
        start_date: str = "2023-01-01",
        end_date: str = None,
        max_period: int = 12,
    ) -> pd.DataFrame:
        """
        Pull cohort retention data from the DB.
        Returns wide-format DataFrame suitable for heatmap visualisation.
        """
        end_date = end_date or pd.Timestamp.now().strftime("%Y-%m-%d")

        query = text("""
            WITH user_cohorts AS (
                SELECT user_id,
                       DATE_TRUNC('month', MIN(order_date))::DATE AS cohort_month
                FROM order_revenue
                WHERE order_date BETWEEN :start_date AND :end_date
                GROUP BY user_id
            ),
            cohort_data AS (
                SELECT
                    uc.cohort_month,
                    (DATE_PART('year', AGE(
                        DATE_TRUNC('month', r.order_date)::DATE, uc.cohort_month
                    )) * 12 +
                    DATE_PART('month', AGE(
                        DATE_TRUNC('month', r.order_date)::DATE, uc.cohort_month
                    )))::INT AS period,
                    COUNT(DISTINCT uc.user_id) AS active_users
                FROM user_cohorts uc
                JOIN order_revenue r USING (user_id)
                WHERE r.order_date >= uc.cohort_month::TIMESTAMPTZ
                  AND (DATE_PART('year', AGE(
                      DATE_TRUNC('month', r.order_date)::DATE, uc.cohort_month
                  )) * 12 + DATE_PART('month', AGE(
                      DATE_TRUNC('month', r.order_date)::DATE, uc.cohort_month
                  ))) <= :max_period
                GROUP BY 1, 2
            ),
            cohort_sizes AS (
                SELECT cohort_month, active_users AS cohort_size
                FROM cohort_data WHERE period = 0
            )
            SELECT
                cd.cohort_month,
                cs.cohort_size,
                cd.period,
                cd.active_users,
                ROUND(100.0 * cd.active_users / cs.cohort_size, 1) AS retention_pct
            FROM cohort_data cd
            JOIN cohort_sizes cs USING (cohort_month)
            ORDER BY cd.cohort_month, cd.period
        """)

        df = pd.read_sql(query, self.engine,
                         params={"start_date": start_date,
                                 "end_date": end_date,
                                 "max_period": max_period})

        # Pivot to wide format for heatmap
        pivot = df.pivot_table(
            index="cohort_month",
            columns="period",
            values="retention_pct",
            aggfunc="first"
        )
        pivot.columns = [f"M{c}" for c in pivot.columns]
        return pivot

    def get_revenue_summary(self, granularity: str = "month") -> pd.DataFrame:
        """
        Pull revenue summary at specified granularity.
        granularity: 'day', 'week', 'month', 'quarter', 'year'
        """
        valid = {"day", "week", "month", "quarter", "year"}
        if granularity not in valid:
            raise ValueError(f"granularity must be one of {valid}")

        query = text(f"""
            SELECT
                DATE_TRUNC('{granularity}', order_date)::DATE AS period,
                COUNT(DISTINCT user_id)                        AS unique_customers,
                COUNT(order_id)                               AS total_orders,
                ROUND(SUM(net_revenue)::NUMERIC, 2)           AS total_revenue,
                ROUND(AVG(net_revenue)::NUMERIC, 2)           AS avg_order_value,
                ROUND(SUM(gross_profit)::NUMERIC, 2)          AS gross_profit,
                ROUND(100.0 * SUM(gross_profit) / NULLIF(SUM(net_revenue), 0), 1)
                                                              AS gross_margin_pct
            FROM order_revenue
            GROUP BY 1
            ORDER BY 1
        """)
        df = pd.read_sql(query, self.engine)
        df["period"] = pd.to_datetime(df["period"])
        # Add MoM growth
        df["revenue_mom_pct"] = df["total_revenue"].pct_change() * 100
        return df

    def get_funnel_metrics(
        self,
        start_date: str,
        end_date: str,
        segment_by: Optional[str] = None
    ) -> pd.DataFrame:
        """
        Pull conversion funnel: page_view → add_to_cart → checkout → purchase.
        Optionally segmented by device_type or referrer.
        """
        segment_col = segment_by if segment_by in ("device_type", "referrer") else "NULL::TEXT"

        query = text(f"""
            SELECT
                {segment_col} AS segment,
                COUNT(DISTINCT session_id)                                           AS sessions,
                COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'add_to_cart')   AS add_to_cart,
                COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'checkout_start') AS checkout_start,
                COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'purchase')       AS purchases,
                -- Step conversion rates
                ROUND(100.0 * COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'add_to_cart')
                    / NULLIF(COUNT(DISTINCT session_id), 0), 1) AS pv_to_cart_pct,
                ROUND(100.0 * COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'checkout_start')
                    / NULLIF(COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'add_to_cart'), 0), 1)
                                                                 AS cart_to_checkout_pct,
                ROUND(100.0 * COUNT(DISTINCT session_id) FILTER (WHERE event_type = 'purchase')
                    / NULLIF(COUNT(DISTINCT session_id), 0), 1) AS overall_conversion_pct
            FROM events
            WHERE event_at BETWEEN :start_date AND :end_date
            GROUP BY 1
            ORDER BY sessions DESC
        """)

        return pd.read_sql(query, self.engine,
                          params={"start_date": start_date, "end_date": end_date})

    def upsert_daily_summary(
        self,
        df: pd.DataFrame,
        table_name: str = "daily_revenue_summary"
    ) -> int:
        """
        Upsert (insert or update) daily summary rows using PostgreSQL ON CONFLICT.
        Returns number of rows affected.
        """
        if df.empty:
            return 0

        records = df.to_dict(orient="records")
        stmt = pg_insert(Table(table_name, MetaData(), autoload_with=self.engine))

        upsert_stmt = stmt.on_conflict_do_update(
            index_elements=["period"],
            set_={col: stmt.excluded[col] for col in df.columns if col != "period"}
        )

        with get_session(self.engine) as session:
            result = session.execute(upsert_stmt, records)
            return result.rowcount


# ── 4. Chunked processing for large tables ────────────────────────────────────

def process_large_table_in_chunks(
    engine,
    query: str,
    process_fn,
    chunk_size: int = 10_000,
    params: Dict = None,
) -> List[Any]:
    """
    Stream a large table in chunks to avoid memory issues.
    process_fn receives each DataFrame chunk and returns a result.

    Example:
        results = process_large_table_in_chunks(
            engine,
            "SELECT * FROM events ORDER BY event_at",
            lambda df: df.groupby("event_type").size().to_dict()
        )
    """
    results = []
    offset = 0
    total_rows = 0

    while True:
        paginated = f"{query} LIMIT {chunk_size} OFFSET {offset}"
        chunk = pd.read_sql(text(paginated), engine, params=params or {})

        if chunk.empty:
            break

        chunk_result = process_fn(chunk)
        if chunk_result is not None:
            results.append(chunk_result)

        total_rows += len(chunk)
        offset += chunk_size
        log.info(f"Processed {total_rows:,} rows...")

        if len(chunk) < chunk_size:
            break

    log.info(f"Total rows processed: {total_rows:,}")
    return results


# ── 5. Quick demo ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s | %(message)s")

    DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/analytics")

    try:
        engine = create_analytics_engine(DATABASE_URL, echo=False)
        db = AnalyticsDB(engine)

        print("\n── Revenue Summary (last 6 months) ──")
        revenue = db.get_revenue_summary("month")
        print(revenue.tail(6).to_string(index=False))

        print("\n── Cohort Retention Heatmap ──")
        cohort = db.get_cohort_retention(max_period=6)
        print(cohort.to_string())

    except Exception as e:
        log.error(f"DB connection failed: {e}")
        log.info("Run schema/create_tables.sql and schema/sample_data.sql first.")
