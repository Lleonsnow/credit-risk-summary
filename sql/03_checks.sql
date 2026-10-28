-- Инварианты витрины. Любое нарушение прерывает выполнение с ошибкой.

DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM (
        SELECT report_date, loan_id FROM reporting.v_loan_mart
        GROUP BY 1, 2 HAVING count(*) > 1
    ) d;
    IF n > 0 THEN RAISE EXCEPTION 'v_loan_mart: % дублей (report_date, loan_id)', n; END IF;

    SELECT count(*) INTO n FROM reporting.v_fx_on_report_date WHERE rate_kzt IS NULL;
    IF n > 0 THEN RAISE EXCEPTION 'нет курса для % пар дата/валюта', n; END IF;

    SELECT count(*) INTO n
    FROM reporting.v_loan_status s
    LEFT JOIN reporting.v_loan_mart m USING (report_date, loan_id)
    WHERE m.loan_id IS NULL AND NOT s.is_written_off;
    IF n > 0 THEN RAISE EXCEPTION 'из витрины потеряно % несписанных кредитов', n; END IF;

    SELECT count(*) INTO n
    FROM (
        SELECT report_date, dimension, sum(portfolio_kzt) AS s
        FROM reporting.v_breakdown GROUP BY 1, 2
    ) b
    JOIN reporting.v_metrics_by_date m USING (report_date)
    WHERE abs(b.s - m.portfolio_kzt) > 0.01;
    IF n > 0 THEN RAISE EXCEPTION 'сумма разреза не равна портфелю (% случаев)', n; END IF;

    SELECT count(*) INTO n
    FROM (
        SELECT report_date, dimension, sum(portfolio_kzt) AS s
        FROM reporting.v_breakdown_stage GROUP BY 1, 2
    ) b
    JOIN reporting.v_metrics_by_date m USING (report_date)
    WHERE abs(b.s - m.portfolio_kzt) > 0.01;
    IF n > 0 THEN RAISE EXCEPTION 'сумма стадий риска не равна портфелю (% случаев)', n; END IF;

    SELECT count(*) INTO n FROM reporting.v_metrics_by_date
    WHERE NOT (par90_kzt <= par30_kzt AND par90_kzt <= npl_kzt AND npl_kzt <= portfolio_kzt
               AND top10_concentration BETWEEN 0 AND 1);
    IF n > 0 THEN RAISE EXCEPTION 'нарушено соотношение PAR90 <= PAR30, PAR90 <= NPL <= портфель'; END IF;

    RAISE NOTICE 'checks: ok';
END $$;
