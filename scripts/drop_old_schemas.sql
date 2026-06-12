-- Run once in Databricks SQL Editor to remove old plain-named schemas
-- created before the ust_* rename (2026-06-12).
-- Safe to run: all objects were recreated under ust_* prefixed schemas.

DROP SCHEMA IF EXISTS ust_databricks.staging   CASCADE;
DROP SCHEMA IF EXISTS ust_databricks.intermediate CASCADE;
DROP SCHEMA IF EXISTS ust_databricks.facts      CASCADE;
DROP SCHEMA IF EXISTS ust_databricks.dq         CASCADE;
DROP SCHEMA IF EXISTS ust_databricks.reporting  CASCADE;
DROP SCHEMA IF EXISTS ust_databricks.seeds      CASCADE;
