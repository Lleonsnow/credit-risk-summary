"""Независимый пересчёт метрик из CSV (без SQL) и сверка с выгрузкой из Postgres.

Использование: python3 scripts/verify.py data/portfolio.csv data/fx.csv dashboard/data/metrics_long.json
"""
import csv
import json
import sys
from collections import defaultdict
from decimal import Decimal

TOLERANCE = Decimal("1e-9")


def load_portfolio(path):
    with open(path, encoding="utf-8") as f:
        rows = {tuple(r.items()): r for r in csv.DictReader(f)}.values()
    by_loan = defaultdict(dict)
    for r in rows:
        by_loan[r["loan_id"]][r["report_date"]] = r
    return by_loan


def load_fx(path):
    with open(path, encoding="utf-8") as f:
        return {(r["date"], r["currency"]): Decimal(r["rate_kzt"]) for r in csv.DictReader(f)}


def rate(fx, date, currency):
    if currency == "KZT":
        return Decimal(1)
    return fx[(date, currency)]


def provision_rate(dpd, npl):
    if npl:
        return Decimal("0.50")
    if dpd > 30:
        return Decimal("0.10")
    return Decimal("0.01")


def compute(by_loan, fx, sticky_write_off=True):
    totals = defaultdict(lambda: defaultdict(Decimal))
    groups = defaultdict(lambda: defaultdict(Decimal))
    for snapshots in by_loan.values():
        written_off = False
        for date in sorted(snapshots):
            r = snapshots[date]
            written_off = (written_off and sticky_write_off) or r["written_off"] == "1"
            if written_off:
                continue
            amount = Decimal(r["principal_outstanding"]) * rate(fx, date, r["currency"])
            dpd = int(r["days_past_due"])
            npl = dpd > 90 or r["restructured"] == "1"
            t = totals[date]
            t["portfolio_kzt"] += amount
            t["par30_kzt"] += amount if dpd > 30 else 0
            t["par90_kzt"] += amount if dpd > 90 else 0
            t["npl_kzt"] += amount if npl else 0
            t["provision_kzt"] += amount * provision_rate(dpd, npl)
            t["loans"] += 1
            groups[date][r["group_id"]] += amount

    result = {}
    for date, t in totals.items():
        top10 = sum(sorted(groups[date].values(), reverse=True)[:10])
        p = t["portfolio_kzt"]
        result[date] = {
            "portfolio_kzt": p,
            "par30_share": t["par30_kzt"] / p,
            "par90_share": t["par90_kzt"] / p,
            "npl_share": t["npl_kzt"] / p,
            "provision_kzt": t["provision_kzt"],
            "provision_share": t["provision_kzt"] / p,
            "top10_concentration": top10 / p,
            "loans": t["loans"],
        }
    return result


def main(portfolio_path, fx_path, metrics_path):
    by_loan = load_portfolio(portfolio_path)
    fx = load_fx(fx_path)
    expected = compute(by_loan, fx)
    with open(metrics_path, encoding="utf-8") as f:
        actual = {(m["report_date"], m["metric"]): Decimal(str(m["value"])) for m in json.load(f)}

    failures = 0
    for date, metrics in sorted(expected.items()):
        for metric, value in metrics.items():
            got = actual.get((date, metric))
            diff = abs(got - value) if got is not None else None
            ok = diff is not None and diff <= TOLERANCE * max(abs(value), 1)
            failures += not ok
            print(f"{'OK ' if ok else 'BAD'} {date} {metric:20} python={value:.6f} sql={got}")

    print("\nСценарий «флаг списания как в данных» (для сравнения):")
    for date, metrics in sorted(compute(by_loan, fx, sticky_write_off=False).items()):
        print(f"  {date} портфель={metrics['portfolio_kzt']:,.0f} NPL={metrics['npl_share']:.4%} "
              f"PAR90={metrics['par90_share']:.4%} провизии={metrics['provision_kzt']:,.0f}")

    if failures:
        sys.exit(f"\nРасхождений: {failures}")
    print("\nВсе метрики совпали.")


if __name__ == "__main__":
    main(*sys.argv[1:4])
