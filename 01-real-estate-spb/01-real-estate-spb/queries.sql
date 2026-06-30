/* ============================================================================
   Проект: Анализ рынка недвижимости Санкт-Петербурга и Ленинградской области
   Источник данных: схема real_estate (архив сервиса Яндекс Недвижимость)
   СУБД: PostgreSQL
   Автор: Екатерина Дорохина
   ----------------------------------------------------------------------------
   Содержание:
     Задача 1. Время активности объявлений
     Задача 2. Сезонность объявлений
   ============================================================================ */

/* ----------------------------------------------------------------------------
   Задача 1. Время активности объявлений

   Цель: определить, какие категории объявлений (по сроку продажи) и какие
   характеристики недвижимости наиболее распространены и как они различаются
   между Санкт-Петербургом и городами Ленинградской области.

   Логика:
     1) limits      — границы выбросов по перцентилям (отсекаем верхний 1 %
                      и аномально низкие потолки);
     2) filtered_id — id объявлений без выбросов (пропуски сохраняем);
     3) grouped_data — агрегаты по категориям срока продажи и регионам;
     4) финальный SELECT — добавляем долю каждой категории внутри региона
                      через оконную функцию.
   Ограничения: только города, годы публикации 2015–2018.
---------------------------------------------------------------------------- */
WITH limits AS (
    SELECT
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY total_area)     AS total_area_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY rooms)          AS rooms_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY balcony)        AS balcony_limit,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_h,
        PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_l
    FROM real_estate.flats
),
filtered_id AS (
    SELECT id
    FROM real_estate.flats
    WHERE total_area < (SELECT total_area_limit FROM limits)
      AND (rooms   < (SELECT rooms_limit   FROM limits) OR rooms   IS NULL)
      AND (balcony < (SELECT balcony_limit FROM limits) OR balcony IS NULL)
      AND (
            (ceiling_height < (SELECT ceiling_height_limit_h FROM limits)
             AND ceiling_height > (SELECT ceiling_height_limit_l FROM limits))
            OR ceiling_height IS NULL
          )
),
grouped_data AS (
    SELECT
        CASE
            WHEN a.days_exposition BETWEEN 1   AND 30  THEN '1-30 days'
            WHEN a.days_exposition BETWEEN 31  AND 90  THEN '31-90 days'
            WHEN a.days_exposition BETWEEN 91  AND 180 THEN '91-180 days'
            WHEN a.days_exposition >= 181              THEN '181+ days'
            ELSE 'non category'
        END AS category,
        CASE
            WHEN c.city = 'Санкт-Петербург' THEN 'Санкт-Петербург'
            ELSE 'Ленинградская область'
        END AS region,
        COUNT(a.id)                                       AS total_flats,
        ROUND(AVG(a.last_price / f.total_area::numeric))  AS price_per_m2,
        ROUND(AVG(f.total_area)::numeric, 2)              AS avg_area,
        ROUND(AVG(f.living_area)::numeric, 2)             AS avg_living_area,
        ROUND(AVG(f.rooms)::numeric)                      AS avg_rooms,
        ROUND(AVG(f.balcony)::numeric)                    AS avg_balcony,
        ROUND(AVG(f.floor)::numeric)                      AS avg_floor
    FROM real_estate.advertisement AS a
    LEFT JOIN real_estate.flats AS f USING (id)
    LEFT JOIN real_estate.city  AS c ON f.city_id = c.city_id
    LEFT JOIN real_estate.type  AS t ON f.type_id = t.type_id
    WHERE EXTRACT(YEAR FROM a.first_day_exposition) BETWEEN 2015 AND 2018
      AND t.type = 'город'
      AND f.id IN (SELECT id FROM filtered_id)
    GROUP BY region, category
)
SELECT
    category,
    region,
    total_flats,
    ROUND(total_flats * 100.0 / SUM(total_flats) OVER (PARTITION BY region), 2)
        AS category_share_percent,   -- доля категории внутри своего региона
    price_per_m2,
    avg_area,
    avg_living_area,
    avg_rooms,
    avg_balcony,
    avg_floor
FROM grouped_data
ORDER BY region, category;


/* ----------------------------------------------------------------------------
   Задача 2. Сезонность объявлений

   Цель: выявить месяцы с повышенной активностью публикации и снятия
   объявлений, а также поведение средней цены за м² и средней площади
   по месяцам.

   Логика:
     1) limits / filtered_id — те же границы выбросов, что в Задаче 1;
     2) months    — для каждого объявления вычисляем месяц публикации и
                    месяц снятия (дата публикации + срок активности);
     3) exp_stat  — статистика по месяцу публикации;
     4) end_stat  — статистика по месяцу снятия;
     5) финальный SELECT — объединяем по номеру месяца и считаем доли
                    публикаций / снятий через оконную функцию.
   Ограничения: только города, годы публикации 2015–2018.

---------------------------------------------------------------------------- */
WITH limits AS (
    SELECT
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY total_area)     AS total_area_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY rooms)          AS rooms_limit,
        PERCENTILE_DISC(0.99) WITHIN GROUP (ORDER BY balcony)        AS balcony_limit,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_h,
        PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY ceiling_height) AS ceiling_height_limit_l
    FROM real_estate.flats
),
filtered_id AS (
    SELECT id
    FROM real_estate.flats
    WHERE total_area < (SELECT total_area_limit FROM limits)
      AND (rooms   < (SELECT rooms_limit   FROM limits) OR rooms   IS NULL)
      AND (balcony < (SELECT balcony_limit FROM limits) OR balcony IS NULL)
      AND (
            (ceiling_height < (SELECT ceiling_height_limit_h FROM limits)
             AND ceiling_height > (SELECT ceiling_height_limit_l FROM limits))
            OR ceiling_height IS NULL
          )
),
months AS (
    SELECT
        a.id,
        EXTRACT(MONTH FROM DATE_TRUNC('month', a.first_day_exposition))::int                       AS exp_month,
        EXTRACT(MONTH FROM DATE_TRUNC('month', a.first_day_exposition + a.days_exposition::int))::int AS end_month,
        a.last_price / f.total_area::numeric                                                        AS price_per_m2,
        f.total_area,
        a.first_day_exposition + a.days_exposition::int                                            AS end_date
    FROM real_estate.advertisement AS a
    LEFT JOIN real_estate.flats AS f USING (id)
    JOIN real_estate.type AS t USING (type_id)
    WHERE EXTRACT(YEAR FROM a.first_day_exposition) BETWEEN 2015 AND 2018
      AND t.type = 'город'
      AND f.id IN (SELECT id FROM filtered_id)
),
exp_stat AS (
    SELECT
        exp_month,
        COUNT(id)                            AS exp_count,
        ROUND(AVG(price_per_m2::numeric))    AS avg_exp_price_per_m2,
        ROUND(AVG(total_area)::numeric, 2)   AS avg_exp_area
    FROM months
    GROUP BY exp_month
),
end_stat AS (
    SELECT
        end_month,
        COUNT(id)                            AS end_count,
        ROUND(AVG(price_per_m2::numeric))    AS avg_end_price_per_m2,
        ROUND(AVG(total_area)::numeric, 2)   AS avg_end_area
    FROM months
    WHERE end_date IS NOT NULL
      AND EXTRACT(YEAR FROM end_date) BETWEEN 2015 AND 2018  -- не выходим за пределы периода
    GROUP BY end_month
)
SELECT
    COALESCE(e.exp_month, s.end_month)                                          AS month,
    e.exp_count,
    ROUND(e.exp_count * 100.0 / SUM(e.exp_count) OVER (), 2)                    AS exp_count_share_percent,
    s.end_count,
    ROUND(s.end_count * 100.0 / SUM(s.end_count) OVER (), 2)                    AS end_count_share_percent,
    e.avg_exp_price_per_m2,
    s.avg_end_price_per_m2,
    e.avg_exp_area,
    s.avg_end_area
FROM exp_stat AS e
FULL JOIN end_stat AS s ON e.exp_month = s.end_month
ORDER BY month;
