                                /*=================================================================
                                        --Creating The Views
                                =================================================================*/



/* ========================================================================
    01_DIMENSION: COUNTRIES
        Purpose: country list with clean region (TRIM removes trailing spaces
        such as "Sub-Saharan Africa ") so slicers do not show duplicates.
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_dim_countries as
    select iso3, iso2, country_name, Trim(region) as region, income_group, capital_city, latitude, longitude
    from stg.Countries;
go

-- to use the view:
select * from rpt.vw_dim_countries;


/* ========================================================================
    02_DIMENSION: YEAR
        Purpose: one row per year (2010-2025). Used to build the
        country x year grid and as the year table in Power BI.
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_dim_year as
    select distinct year
    from stg.Annual_Oil_Trade;
go

-- to use the view :
select * from rpt.vw_dim_year;


/* ========================================================================
    03_FACT: MASTER ANALYSIS
        Purpose: one row per country per year (150 x 16 = 2,400) with all
        joined measures and calculated ratios. Missing values stay NULL.
        Every other view reads from this one.
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_master_analysis as
    select
    c.iso3,
    c.country_name,
    c.region,
    c.income_group,
    y.year,
    m.gdp_usd,
    t.crude_oil_import_usd,
    t.crude_oil_export_usd,
    o.oil_consumption_twh,
    f.exchange_rate_lcu_per_usd,
    100 * t.crude_oil_import_usd / nullif(m.gdp_usd, 0) as import_burden_pct,
    100 * t.crude_oil_export_usd / nullif(m.gdp_usd, 0) as export_dep_pct,
    t.crude_oil_import_usd - t.crude_oil_export_usd as net_crude_trade,
    case when t.crude_oil_import_usd is null or t.crude_oil_export_usd is null then 'No data'
         when t.crude_oil_import_usd > t.crude_oil_export_usd then 'Net importer'
         else 'Net exporter' end as net_status,
    o.oil_consumption_twh / nullif(m.gdp_usd / 1e9, 0) as oil_intensity
    from rpt.vw_dim_countries c
    cross join rpt.vw_dim_year y 
    left join stg.Annual_Oil_Trade t on t.iso3 = c.iso3 and t.year = y.year
    left join stg.Annual_Macro_Indicators m on m.iso3 = c.iso3 and m.year = y.year
    left join stg.Annual_Oil_Consumption o on o.iso3 = c.iso3 and o.year = y.year
    left join stg.Annual_Exchange_Rates_FX f on f.iso3 = c.iso3 and f.year = y.year
    ;
go


-- to use the view :
select * from rpt.vw_master_analysis;


/* ========================================================================
    04_PRICES: ANNUAL
        Purpose: average Brent and WTI per year. Filtered to <= 2025 because
        the monthly file also contains 2026 months with no matching year.
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_prices_annual as
    select
    year(period) as [year],
    avg(brent_usd_bbl) as brent,
    avg(wti_usd_bbl) as wti
    from stg.Monthly_Oil_Prices
    where year(period) <= 2025
    group by year(period)
;
go

-- to use the view :
select * from rpt.vw_prices_annual;


/* ========================================================================
    05_FACT: MASTER ENRICHED
        Purpose: master_analysis plus the 3 calculated columns from Excel:
            burden_band     - import burden group "1) No data ... 7) >5%"
            panel_burden    - 1 if the country has burden data in every year 2010-2024
            panel_intensity - 1 if the country has oil intensity in every year 2010-2024

        Panels keep the sample fixed so trends are not caused by changing countries.
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_master_enriched as
    with base as (
        select
        m.*,
        count(case when [year] <= 2024 then import_burden_pct end) over (partition by iso3) as n_burden_valid,
        count(case when [year] <= 2024 then oil_intensity end) over (partition by iso3) as n_intensity_valid,
        sum(case when [year] <= 2024 then 1 else 0 end) over (partition by iso3) as n_rows
        from rpt.vw_master_analysis m
    )
    select
    iso3,
    country_name,
    region,
    income_group,
    [year],
    gdp_usd,
    crude_oil_import_usd,
    crude_oil_export_usd,
    oil_consumption_twh,
    exchange_rate_lcu_per_usd,
    import_burden_pct,
    export_dep_pct,
    net_crude_trade,
    net_status,
    oil_intensity,
    case when import_burden_pct is null then '1) No data'
         when import_burden_pct < 0.01 then '2) <0.01% (verify)'
         when import_burden_pct < 0.1 then '3) 0.01-0.1%'
         when import_burden_pct < 1 then '4) 0.1-1%'
         when import_burden_pct < 3 then '5) 1-3%'
         when import_burden_pct <= 5 then '6) 3-5%'
         else '7) >5%' end as burden_band,
    case when n_burden_valid = n_rows then 1 else 0 end as panel_burden,
    case when n_intensity_valid = n_rows then 1 else 0 end as panel_intensity
    from base
;
go

-- to use the view :
select * from rpt.vw_master_enriched;


/* ========================================================================
    06_ANSWER Pivot-1: BURDEN BANDS
        Purpose: how many countries fall in each import-burden band, including
        "No data". Filter one year (e.g. where [year] = 2024) when you query it.
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_p1_burden_bands as
    select
    [year],
    region,
    income_group,
    burden_band,
    count(distinct iso3) as countries
    from rpt.vw_master_enriched
    group by [year], region, income_group, burden_band
;
go

-- to use the view :
select * from rpt.vw_p1_burden_bands;


/* ========================================================================
    07_ANSWER Pivot-2: Export Dependence
        Purpose: crude export value as % of GDP, ranked within each year
        (rank 1 = most dependent). Only countries with export data appear.
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_p2_export_dependence as
    select
    [year],
    iso3,
    country_name,
    region,
    income_group,
    export_dep_pct,
    rank() over (partition by [year] order by export_dep_pct desc) as rank_in_year
    from rpt.vw_master_analysis
    where export_dep_pct is not null
;
go

-- to use the view :
select * from rpt.vw_p2_export_dependence;


/* ========================================================================
    08_ANSWER Pivot-3: NET CRUDE TRADE BY REGION
        Purpose: net trade in USD billions per region and status. Importers are
        positive, exporters negative. Countries with "No data" are excluded
        (complete-case rule), so totals do not net to zero (CIF vs FOB).
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_p3_net_trade as
    select
    [year],
    region,
    net_status,
    sum(net_crude_trade) / 1e9 as net_trade_bn,
    count(distinct iso3) as countries
    from rpt.vw_master_analysis
    where net_status <> 'No data'
    group by [year], region, net_status
;
go

-- to use the view :
select * from rpt.vw_p3_net_trade;


/* ========================================================================
    09_ANSWER Pivot-4: PANEL BURDEN VS BRENT
        Purpose: aggregate import burden (sum imports / sum GDP) of the fixed
        panel for each year, next to average Brent. Years 2010-2024 only.
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_p4_brent_vs_panel as
    select
    e.[year],
    count(distinct e.iso3) as panel_countries,
    100.0 * sum(e.crude_oil_import_usd) / sum(e.gdp_usd) as panel_burden_pct,
    p.brent as brent_avg
    from rpt.vw_master_enriched e
    join rpt.vw_prices_annual p on p.[year] = e.[year]
    where e.panel_burden = 1 and e.[year] <= 2024
    group by e.[year], p.brent
;
go

-- to use the ciew :
select * from rpt.vw_p4_brent_vs_panel;


/* ========================================================================
    10_ANSWER Pivot-5: CURRENCY EFFECT 2020 -> 2022
        Purpose: splits growth of the local-currency import bill into:
            usd_effect_log_pts - growth of the bill in USD
            fx_effect_log_pts  - rise in local currency units per USD

        Log points add up exactly. Only countries with imports >= $100M in both
        years and valid exchange rates are included.
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_p5_currency_effect as
    select
    a.iso3,
    a.country_name,
    a.region,
    a.income_group,
    a.crude_oil_import_usd as import_2020_usd,
    z.crude_oil_import_usd as import_2022_usd,
    a.exchange_rate_lcu_per_usd as fx_2020,
    z.exchange_rate_lcu_per_usd as fx_2022,
    100.0 * log(z.crude_oil_import_usd / a.crude_oil_import_usd) as usd_effect_log_pts,
    100.0 * log(z.exchange_rate_lcu_per_usd / a.exchange_rate_lcu_per_usd) as fx_effect_log_pts
    from rpt.vw_master_analysis a
    join rpt.vw_master_analysis z on z.iso3 = a.iso3 and z.[year] = 2022
    where a.[year] = 2020
      and a.crude_oil_import_usd >= 1e8 and z.crude_oil_import_usd >= 1e8
      and a.exchange_rate_lcu_per_usd > 0 and z.exchange_rate_lcu_per_usd > 0
;
go

-- to use the view :
select * from rpt.vw_p5_currency_effect;


/* ========================================================================
    11_ANSWER Pivot-6: OIL INTENSITY BY INCOME GROUP
        Purpose: oil consumption (TWh) per USD billion of GDP for the fixed
        intensity panel, by year and income group. Years 2010-2024 only.
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_p6_oil_intensity as
    select
    [year],
    income_group,
    count(distinct iso3) as panel_countries,
    sum(oil_consumption_twh) / (sum(gdp_usd) / 1e9) as oil_intensity_twh_per_bn
    from rpt.vw_master_enriched
    where panel_intensity = 1 and [year] <= 2024
    group by [year], income_group
;
go

-- to use the view :
select * from rpt.vw_p6_oil_intensity;


/* ========================================================================
    12_KPI: SUMMARY
        Purpose: one row per year with the numbers for the dashboard KPI cards
        (coverage, countries above thresholds, importers, exporters).
======================================================================== */

use GES2026;

go

create or alter view rpt.vw_kpi_summary as
    select
    [year],
    count(*) as countries_in_selection,
    count(import_burden_pct) as countries_with_burden,
    cast(count(import_burden_pct) as float) / count(*) as burden_coverage,
    sum(case when import_burden_pct >= 3 then 1 else 0 end) as countries_burden_ge_3,
    count(export_dep_pct) as countries_with_export_dep,
    sum(case when export_dep_pct >= 5 then 1 else 0 end) as countries_export_dep_ge_5,
    sum(case when net_status = 'Net importer' then 1 else 0 end) as countries_net_importer,
    sum(case when net_status = 'Net exporter' then 1 else 0 end) as countries_net_exporter,
    count(net_crude_trade) as countries_with_net_trade
    from rpt.vw_master_analysis
    group by [year]
;
go

-- To use the View :
select * from rpt.vw_kpi_summary;


--===========================================================================================================================================--

/* ==========================
  QUICK VALIDATION QUERIES 
========================== */

-- 1) Row counts of the core views
--    Checks that the joins did not duplicate or lose rows.
--    Expected: dim_countries 150 | dim_year 16 | master_analysis 2400
--               prices_annual 16 | master_enriched 2400
select 'dim_countries' as view_name, count(*) as n from rpt.vw_dim_countries
union all
select 'dim_year', count(*) from rpt.vw_dim_year
union all
select 'master_analysis', count(*) from rpt.vw_master_analysis
union all
select 'prices_annual', count(*) from rpt.vw_prices_annual
union all
select 'master_enriched', count(*) from rpt.vw_master_enriched;


-- 2) Net trade status distribution (all years)
--    Checks the net_importer / net_exporter / no data logic.
--    Expected: Net exporter 534 | Net importer 748 | No data 1118
select net_status, count(*) as n
from rpt.vw_master_analysis
group by net_status
order by net_status;


-- 3) Fixed panels (same countries in every year 2010-2024)
--    Checks the panel_burden and panel_intensity flags.
--    Expected: panel_burden_countries 70 | panel_intensity_countries 144
select count(distinct case when panel_burden = 1 then iso3 end) as panel_burden_countries,
       count(distinct case when panel_intensity = 1 then iso3 end) as panel_intensity_countries
from rpt.vw_master_enriched;


-- 4) Key 2024 numbers (must match the Excel dashboard)
--    Expected: with_burden: 93 | burden_ge_3: 7 | export_ge_5: 14 | importers: 40 | exporters: 28
select count(import_burden_pct) as with_burden,
       sum(case when import_burden_pct >= 3 then 1 else 0 end) as burden_ge_3,
       sum(case when export_dep_pct >= 5 then 1 else 0 end) as export_ge_5,
       sum(case when net_status = 'Net importer' then 1 else 0 end) as importers,
       sum(case when net_status = 'Net exporter' then 1 else 0 end) as exporters
from rpt.vw_master_analysis
where [year] = 2024;


-- 5) Panel import burden vs Brent, by year (Question P4)
--    Burden = sum of imports / sum of GDP for the fixed panel, in %.
--    Expected: 15 rows (2010-2024)
--              burden 1.92 (2010) | 2.41 (2012) | 0.75 (2020) | 1.45 (2022) | 1.11 (2024)
--              Brent  about 41.8 (2020) and 100.8 (2022)
select e.[year],
       round(100.0 * sum(e.crude_oil_import_usd) / sum(e.gdp_usd), 2) as panel_burden_pct,
       round(p.brent, 1) as brent_avg
from rpt.vw_master_enriched e
join rpt.vw_prices_annual p on p.[year] = e.[year]
where e.panel_burden = 1 AND e.[year] <= 2024
group by e.[year], p.brent
order by e.[year];


-- 6) Currency effect window
--    Expected: countries_in_window: 44 | fx_gt_10: 7
select count(*) as countries_in_window,
       sum(case when fx_effect_log_pts > 10 then 1 else 0 end) as fx_gt_10
from rpt.vw_p5_currency_effect;


