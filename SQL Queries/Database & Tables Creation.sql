/*=================================================================
        01_Create Database and Schema
=================================================================*/
if db_id('GES2026') is null
    create database GES2026;
go
USE GES2026;
go
if not exists (select 1 from sys.schemas where name = 'stg') exec('create schema stg');
go
if not exists (select 1 from sys.schemas where name = 'rpt') exec('create schema rpt');
go




/*=================================================================
        02_Check Row Counts
=================================================================*/
use GES2026;

select 'Countries' as tbl, count(*) as num from stg.Countries
union all
select 'Monthly_Oil_Production', count(*) from stg.Monthly_Oil_Production 
union all
select 'Monthly_Oil_Prices', count(*) from stg.Monthly_Oil_Prices 
union all
select 'Annual_Macro_Indicators', count(*) from stg.Annual_Macro_Indicators 
union all
select 'Annual_Oil_Trade', count(*) from stg.Annual_Oil_Trade 
union all
select 'Annual_Oil_Consumption', count(*) from stg.Annual_Oil_Consumption 
union all
select 'Annual_Exchange_Rates_FX', count(*) from stg.Annual_Exchange_Rates_FX 
union all
select 'Country_Exposure_Scores_2024', count(*) from stg.Country_Exposure_Scores_2024;



/*=================================================================
        03_Checking If The Nulls Still Null or Became Zero
=================================================================*/
use GES2026;

select 'gdp_usd' as col, count(gdp_usd) as non_null, sum(case when gdp_usd = 0 then 1 else 0 end) as zeros
from stg.Annual_Macro_Indicators 
union all
select 'crude_oil_import_usd', count(crude_oil_import_usd), sum(case when crude_oil_import_usd = 0 then 1 else 0 end)
from stg.Annual_Oil_Trade 
union all
select 'crude_oil_export_usd', count(crude_oil_export_usd), sum(case when crude_oil_export_usd = 0 then 1 else 0 end)
from stg.Annual_Oil_Trade 
union all
select 'oil_consumption_twh', count(oil_consumption_twh), sum(case when oil_consumption_twh = 0 then 1 else 0 end)
from stg.Annual_Oil_Consumption 
union all
select 'exchange_rate_lcu_per_usd', count(exchange_rate_lcu_per_usd), sum(case when exchange_rate_lcu_per_usd = 0 then 1 else 0 end)
from stg.Annual_Exchange_Rates_FX;




/*=================================================================
         04_Quality Checks
=================================================================*/

use GES2026;

    -- 1) Duplicates in iso3 and year columns, Must be nothing in all these 4 quries.
select iso3,[year],count(*) c from stg.Annual_Macro_Indicators  group by iso3,[year] having count(*) >1;
select iso3,[year],count(*) c from stg.Annual_Oil_Trade         group by iso3,[year] having count(*) >1;
select iso3,[year],count(*) c from stg.Annual_Oil_Consumption   group by iso3,[year] having count(*) >1;
select iso3,[year],count(*) c from stg.Annual_Exchange_Rates_FX group by iso3,[year] having count(*) >1;

    -- 2) The range of Years, Must be 2010-2025.
select min([year]) as mn, max([year]) as mx from stg.Annual_Oil_Trade;

    -- 3) Countries codes that does not exist, Must be nothing.
select distinct t.iso3
from stg.Annual_Oil_Trade t left join stg.Countries c 
on c.iso3 = t.iso3 
where c.iso3 is null;

    -- 4) The range of the Monthly Prices, Must be from '2010-01-01 To 2026-05-01'.
select min(period) as mn, max(period) as mx from stg.Monthly_Oil_Prices;

    -- 5) Checking if there is any extra spaces in Region column in Countries table
select distinct region, len(region) as len_trimmed, datalength(region)/2 as len_raw
from stg.Countries
where len(region) <> datalength(region)/2;

