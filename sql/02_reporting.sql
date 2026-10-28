-- Витрина и метрики в схеме reporting. Только CREATE OR REPLACE VIEW — повторный запуск безопасен.

CREATE SCHEMA IF NOT EXISTS reporting;

-- Курс к тенге на каждую дату среза. KZT = 1.
-- Если курса на дату нет, берётся последний известный до неё (rate_date покажет, какой именно).
CREATE OR REPLACE VIEW reporting.v_fx_on_report_date AS
SELECT d.report_date,
       c.currency,
       CASE WHEN c.currency = 'KZT' THEN 1::numeric ELSE r.rate_kzt END AS rate_kzt,
       CASE WHEN c.currency = 'KZT' THEN d.report_date ELSE r.date END AS rate_date
FROM (SELECT DISTINCT report_date FROM raw.portfolio) d
CROSS JOIN (SELECT DISTINCT currency FROM raw.portfolio) c
LEFT JOIN LATERAL (
    SELECT f.date, f.rate_kzt
    FROM raw.fx f
    WHERE f.currency = c.currency
      AND f.date <= d.report_date
    ORDER BY f.date DESC
    LIMIT 1
) r ON true;

-- Все кредиты без дублей, с признаками риска. Включает списанные — для контроля и миграций.
-- Списание необратимо: если кредит списан на каком-то срезе, он считается списанным и на всех следующих.
CREATE OR REPLACE VIEW reporting.v_loan_status AS
WITH dedup AS (
    SELECT DISTINCT ON (report_date, loan_id) *
    FROM raw.portfolio
    ORDER BY report_date, loan_id, written_off DESC, days_past_due DESC
),
flagged AS (
    SELECT d.*,
           bool_or(d.written_off = 1) OVER (
               PARTITION BY d.loan_id ORDER BY d.report_date
           ) AS is_written_off
    FROM dedup d
),
classified AS (
    SELECT f.*,
           fx.rate_kzt AS fx_rate,
           f.principal_outstanding * fx.rate_kzt AS principal_kzt,
           f.restructured = 1 AS is_restructured,
           f.days_past_due > 30 AS is_par30,
           f.days_past_due > 90 AS is_par90,
           f.days_past_due > 90 OR f.restructured = 1 AS is_npl
    FROM flagged f
    JOIN reporting.v_fx_on_report_date fx
      ON fx.report_date = f.report_date AND fx.currency = f.currency
)
SELECT report_date,
       loan_id,
       borrower_id,
       group_id,
       sector,
       program,
       currency,
       issue_date,
       maturity_date,
       principal_outstanding,
       fx_rate,
       principal_kzt,
       days_past_due,
       CASE
           WHEN days_past_due = 0 THEN '0'
           WHEN days_past_due <= 30 THEN '1-30'
           WHEN days_past_due <= 90 THEN '31-90'
           ELSE '90+'
       END AS dpd_bucket,
       CASE
           WHEN days_past_due = 0 THEN 1
           WHEN days_past_due <= 30 THEN 2
           WHEN days_past_due <= 90 THEN 3
           ELSE 4
       END AS dpd_bucket_order,
       CASE
           WHEN is_npl THEN 'NPL'
           WHEN days_past_due > 30 THEN 'Просрочка 31-90'
           ELSE 'Стандартные (до 30)'
       END AS risk_stage,
       CASE
           WHEN is_npl THEN 0.50
           WHEN days_past_due > 30 THEN 0.10
           ELSE 0.01
       END AS provision_rate,
       is_restructured,
       is_par30,
       is_par90,
       is_npl,
       is_written_off,
       written_off = 1 AS written_off_raw,
       maturity_date < report_date AS is_past_maturity
FROM classified;

-- Очищенная витрина: кредитный портфель без списанных, суммы в тенге.
CREATE OR REPLACE VIEW reporting.v_loan_mart AS
SELECT report_date,
       loan_id,
       borrower_id,
       group_id,
       sector,
       program,
       currency,
       issue_date,
       maturity_date,
       principal_outstanding,
       fx_rate,
       principal_kzt,
       days_past_due,
       dpd_bucket,
       dpd_bucket_order,
       risk_stage,
       provision_rate,
       principal_kzt * provision_rate AS provision_kzt,
       CASE WHEN is_par30 THEN principal_kzt ELSE 0 END AS par30_kzt,
       CASE WHEN is_par90 THEN principal_kzt ELSE 0 END AS par90_kzt,
       CASE WHEN is_npl THEN principal_kzt ELSE 0 END AS npl_kzt,
       is_restructured,
       is_par30,
       is_par90,
       is_npl,
       is_past_maturity
FROM reporting.v_loan_status
WHERE NOT is_written_off;

-- Метрики на каждую дату среза.
CREATE OR REPLACE VIEW reporting.v_metrics_by_date AS
WITH groups AS (
    SELECT report_date,
           group_id,
           sum(principal_kzt) AS group_kzt,
           row_number() OVER (
               PARTITION BY report_date ORDER BY sum(principal_kzt) DESC, group_id
           ) AS group_rank
    FROM reporting.v_loan_mart
    GROUP BY report_date, group_id
),
top10 AS (
    SELECT report_date, sum(group_kzt) AS top10_groups_kzt
    FROM groups
    WHERE group_rank <= 10
    GROUP BY report_date
),
totals AS (
    SELECT report_date,
           count(*) AS loans,
           count(DISTINCT borrower_id) AS borrowers,
           count(DISTINCT group_id) AS groups,
           sum(principal_kzt) AS portfolio_kzt,
           sum(par30_kzt) AS par30_kzt,
           sum(par90_kzt) AS par90_kzt,
           sum(npl_kzt) AS npl_kzt,
           sum(provision_kzt) AS provision_kzt
    FROM reporting.v_loan_mart
    GROUP BY report_date
)
SELECT t.report_date,
       t.loans,
       t.borrowers,
       t.groups,
       t.portfolio_kzt,
       t.par30_kzt,
       t.par90_kzt,
       t.npl_kzt,
       t.provision_kzt,
       c.top10_groups_kzt,
       t.par30_kzt / t.portfolio_kzt AS par30_share,
       t.par90_kzt / t.portfolio_kzt AS par90_share,
       t.npl_kzt / t.portfolio_kzt AS npl_share,
       t.provision_kzt / t.portfolio_kzt AS provision_share,
       c.top10_groups_kzt / t.portfolio_kzt AS top10_concentration
FROM totals t
JOIN top10 c USING (report_date);

-- Те же метрики в длинном формате: одна строка = метрика × дата.
CREATE OR REPLACE VIEW reporting.v_metrics_long AS
SELECT m.report_date, v.metric_order, v.metric, v.label, v.unit, v.value
FROM reporting.v_metrics_by_date m
CROSS JOIN LATERAL (VALUES
    (1, 'portfolio_kzt',       'Портфель, ₸',              'kzt',   m.portfolio_kzt),
    (2, 'par30_share',         'PAR30',                    'share', m.par30_share),
    (3, 'par90_share',         'PAR90',                    'share', m.par90_share),
    (4, 'npl_share',           'NPL',                      'share', m.npl_share),
    (5, 'provision_kzt',       'Провизии, ₸',              'kzt',   m.provision_kzt),
    (6, 'provision_share',     'Провизии / портфель',      'share', m.provision_share),
    (7, 'top10_concentration', 'Концентрация топ-10 групп', 'share', m.top10_concentration),
    (8, 'loans',               'Кредитов в портфеле',      'count', m.loans::numeric)
) AS v(metric_order, metric, label, unit, value);

-- Метрики на последнюю дату с изменением к первой (01.10 к 01.09).
-- Для долей change_abs — это изменение в долях (×100 = п.п.).
CREATE OR REPLACE VIEW reporting.v_metrics_change AS
WITH bounds AS (
    SELECT min(report_date) AS date_base, max(report_date) AS date_current
    FROM reporting.v_metrics_by_date
)
SELECT cur.metric_order,
       cur.metric,
       cur.label,
       cur.unit,
       b.date_base,
       b.date_current,
       base.value AS value_base,
       cur.value AS value_current,
       cur.value - base.value AS change_abs,
       (cur.value - base.value) / NULLIF(base.value, 0) AS change_rel
FROM bounds b
JOIN reporting.v_metrics_long cur ON cur.report_date = b.date_current
JOIN reporting.v_metrics_long base ON base.report_date = b.date_base AND base.metric = cur.metric;

-- Разрезы по отрасли и программе.
CREATE OR REPLACE VIEW reporting.v_breakdown AS
WITH agg AS (
    SELECT report_date,
           CASE WHEN GROUPING(sector) = 0 THEN 'sector' ELSE 'program' END AS dimension,
           COALESCE(sector, program) AS dimension_value,
           count(*) AS loans,
           sum(principal_kzt) AS portfolio_kzt,
           sum(par30_kzt) AS par30_kzt,
           sum(npl_kzt) AS npl_kzt,
           sum(provision_kzt) AS provision_kzt
    FROM reporting.v_loan_mart
    GROUP BY GROUPING SETS ((report_date, sector), (report_date, program))
)
SELECT a.*,
       a.portfolio_kzt / sum(a.portfolio_kzt) OVER (PARTITION BY a.report_date, a.dimension) AS portfolio_share,
       a.par30_kzt / a.portfolio_kzt AS par30_share,
       a.npl_kzt / a.portfolio_kzt AS npl_share,
       a.provision_kzt / a.portfolio_kzt AS provision_share
FROM agg a;

-- Структура портфеля по стадиям риска в разрезах (для стековых графиков).
CREATE OR REPLACE VIEW reporting.v_breakdown_stage AS
SELECT report_date,
       CASE WHEN GROUPING(sector) = 0 THEN 'sector' ELSE 'program' END AS dimension,
       COALESCE(sector, program) AS dimension_value,
       risk_stage,
       sum(principal_kzt) AS portfolio_kzt
FROM reporting.v_loan_mart
GROUP BY GROUPING SETS ((report_date, sector, risk_stage), (report_date, program, risk_stage));

-- Десять крупнейших групп связанных заёмщиков на каждую дату.
CREATE OR REPLACE VIEW reporting.v_top_groups AS
WITH groups AS (
    SELECT report_date,
           group_id,
           count(*) AS loans,
           sum(principal_kzt) AS group_kzt,
           sum(npl_kzt) AS npl_kzt,
           row_number() OVER (
               PARTITION BY report_date ORDER BY sum(principal_kzt) DESC, group_id
           ) AS group_rank
    FROM reporting.v_loan_mart
    GROUP BY report_date, group_id
)
SELECT g.report_date,
       g.group_rank,
       g.group_id,
       g.loans,
       g.group_kzt,
       g.group_kzt / m.portfolio_kzt AS portfolio_share,
       g.npl_kzt / g.group_kzt AS npl_share
FROM groups g
JOIN reporting.v_metrics_by_date m USING (report_date)
WHERE g.group_rank <= 10;

-- Миграция кредитов между корзинами просрочки от среза к следующему срезу.
-- Сумма — остаток в тенге на начальную дату. «Списан» — кредит списан к следующему срезу.
CREATE OR REPLACE VIEW reporting.v_dpd_migration AS
WITH dates AS (
    SELECT report_date, lead(report_date) OVER (ORDER BY report_date) AS next_date
    FROM (SELECT DISTINCT report_date FROM reporting.v_loan_status) d
)
SELECT f.report_date AS date_from,
       t.report_date AS date_to,
       f.dpd_bucket AS bucket_from,
       f.dpd_bucket_order AS bucket_from_order,
       CASE WHEN t.is_written_off THEN 'Списан' ELSE t.dpd_bucket END AS bucket_to,
       CASE WHEN t.is_written_off THEN 5 ELSE t.dpd_bucket_order END AS bucket_to_order,
       count(*) AS loans,
       sum(f.principal_kzt) AS portfolio_kzt_from
FROM reporting.v_loan_status f
JOIN dates d ON d.report_date = f.report_date
JOIN reporting.v_loan_status t ON t.loan_id = f.loan_id AND t.report_date = d.next_date
WHERE NOT f.is_written_off
GROUP BY 1, 2, 3, 4, 5, 6;

-- Контроль качества данных: что найдено в сырье и как обработано.
CREATE OR REPLACE VIEW reporting.v_data_quality AS
SELECT 'duplicate_rows' AS check_name,
       report_date,
       count(*) - count(DISTINCT loan_id) AS rows_affected,
       'Полные дубли строк в raw.portfolio, удалены в витрине' AS note
FROM raw.portfolio
GROUP BY report_date
UNION ALL
SELECT 'write_off_reversed',
       report_date,
       count(*) FILTER (WHERE is_written_off AND NOT written_off_raw),
       'Кредит был списан ранее, а в срезе written_off = 0; считается списанным'
FROM reporting.v_loan_status
GROUP BY report_date
UNION ALL
SELECT 'written_off_excluded',
       report_date,
       count(*) FILTER (WHERE is_written_off),
       'Списанные кредиты, исключены из портфеля'
FROM reporting.v_loan_status
GROUP BY report_date
UNION ALL
SELECT 'fx_rate_not_on_report_date',
       report_date,
       count(*) FILTER (WHERE rate_date IS DISTINCT FROM report_date),
       'Валюты без курса ровно на дату среза'
FROM reporting.v_fx_on_report_date
GROUP BY report_date
UNION ALL
SELECT 'past_maturity_no_dpd',
       report_date,
       count(*) FILTER (WHERE is_past_maturity AND days_past_due = 0),
       'Срок погашения прошёл, а просрочки нет; оставлены как есть'
FROM reporting.v_loan_mart
GROUP BY report_date;
