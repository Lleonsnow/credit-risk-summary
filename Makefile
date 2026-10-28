PSQL = docker compose exec -T db psql -U risk -d risk -v ON_ERROR_STOP=1 -q
DATA = dashboard/data
PORT = 8000

.PHONY: all up load views check export verify serve screenshot screenshot-mobile down

all: up load views check export verify

up:
	docker compose up -d --wait

load:
	$(PSQL) -f /sql/01_raw.sql

views:
	$(PSQL) -f /sql/02_reporting.sql

check:
	$(PSQL) -f /sql/03_checks.sql

# Выгрузка вьюх в JSON для дашборда. Файлы пишутся с хоста — права остаются у текущего пользователя.
export:
	@mkdir -p $(DATA)
	@for v in metrics_long:report_date,metric_order metrics_change:metric_order breakdown:report_date,dimension,dimension_value \
	          breakdown_stage:report_date,dimension,dimension_value,risk_stage top_groups:report_date,group_rank \
	          dpd_migration:date_from,bucket_from_order,bucket_to_order data_quality:check_name,report_date; do \
		name=$${v%%:*}; order=$${v#*:}; \
		$(PSQL) -At -c "SELECT coalesce(json_agg(t ORDER BY $$order), '[]') FROM reporting.v_$$name t" > $(DATA)/$$name.json; \
		echo "$(DATA)/$$name.json"; \
	done

verify:
	python3 -I scripts/verify.py data/portfolio.csv data/fx.csv $(DATA)/metrics_long.json

serve:
	python3 -m http.server $(PORT) -d dashboard

screenshot:
	google-chrome --headless=new --disable-gpu --hide-scrollbars --virtual-time-budget=10000 \
		--user-data-dir=$$(mktemp -d) --no-first-run \
		--window-size=1440,3050 --screenshot=$(CURDIR)/docs/dashboard.png http://localhost:$(PORT)/?static=1

screenshot-mobile:
	google-chrome --headless=new --disable-gpu --hide-scrollbars --virtual-time-budget=10000 \
		--user-data-dir=$$(mktemp -d) --no-first-run \
		--window-size=390,6140 --screenshot=$(CURDIR)/docs/dashboard-mobile.png http://localhost:$(PORT)/?static=1

down:
	docker compose down
