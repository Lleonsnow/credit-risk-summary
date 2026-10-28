-- Загрузка CSV в схему raw «как есть» (дубли и аномалии не чистятся).
-- Идемпотентно: таблицы создаются один раз, данные перезаливаются в одной транзакции.

CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE IF NOT EXISTS raw.portfolio (
    report_date           date           NOT NULL,
    loan_id               text           NOT NULL,
    borrower_id           text           NOT NULL,
    group_id              text           NOT NULL,
    sector                text           NOT NULL,
    program               text           NOT NULL,
    currency              char(3)        NOT NULL,
    issue_date            date           NOT NULL,
    maturity_date         date           NOT NULL,
    principal_outstanding numeric(20, 2) NOT NULL,
    days_past_due         integer        NOT NULL,
    restructured          smallint       NOT NULL,
    written_off           smallint       NOT NULL
);

CREATE TABLE IF NOT EXISTS raw.fx (
    date     date          NOT NULL,
    currency char(3)       NOT NULL,
    rate_kzt numeric(12, 4) NOT NULL
);

BEGIN;
TRUNCATE raw.portfolio, raw.fx;
COPY raw.portfolio FROM '/data/portfolio.csv' WITH (FORMAT csv, HEADER true);
COPY raw.fx FROM '/data/fx.csv' WITH (FORMAT csv, HEADER true);
COMMIT;
