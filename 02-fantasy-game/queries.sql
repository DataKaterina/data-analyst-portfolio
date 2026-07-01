/* ============================================================================
   Проект: «Секреты Тёмнолесья» — анализ внутриигровых покупок
   Источник данных: схема fantasy (данные MMORPG)
   СУБД: PostgreSQL
   Автор: Екатерина Дорохина
   ----------------------------------------------------------------------------
   Цель: изучить, как характеристики игроков и их персонажей влияют на покупку
   внутриигровой валюты «райские лепестки», и оценить активность игроков при
   совершении внутриигровых покупок.

   Содержание:
     Часть 1. Исследовательский анализ
        1.1 Доля платящих игроков (всего и по расам)
        1.2 Статистика внутриигровых покупок
        1.3 Аномальные покупки
        1.4 Популярные эпические предметы
     Часть 2. Ad hoc: зависимость активности от расы персонажа
   ============================================================================ */


/* ----------------------------------------------------------------------------
   Часть 1. Исследовательский анализ данных
---------------------------------------------------------------------------- */

-- 1.1. Доля платящих пользователей по всем данным
SELECT
    COUNT(*)                                          AS total_users,
    SUM(payer)                                        AS total_payers,
    ROUND(SUM(payer) / COUNT(*)::numeric * 100, 2)    AS payers_share_percent
FROM fantasy.users;


-- 1.1. Доля платящих пользователей в разрезе расы персонажа
SELECT
    r.race,
    SUM(u.payer)                                        AS total_payers,
    COUNT(u.id)                                         AS total_users,
    ROUND(SUM(u.payer) / COUNT(u.id)::numeric * 100, 2) AS payers_share_percent
FROM fantasy.users AS u
LEFT JOIN fantasy.race AS r USING (race_id)
GROUP BY r.race
ORDER BY payers_share_percent DESC;


-- 1.2. Статистические показатели по стоимости покупок (поле amount),
--      без учёта нулевых покупок
SELECT
    COUNT(transaction_id)                                       AS total_transactions,
    SUM(amount)                                                 AS total_amount,
    MIN(amount)                                                 AS min_amount,
    MAX(amount)                                                 AS max_amount,
    ROUND(AVG(amount)::numeric, 2)                              AS avg_amount,
    PERCENTILE_DISC(0.50) WITHIN GROUP (ORDER BY amount)        AS median_amount,
    ROUND(STDDEV(amount)::numeric, 2)                           AS stddev_amount
FROM fantasy.events
WHERE amount > 0;


-- 1.3. Аномальные покупки: доля нулевых транзакций
SELECT
    COUNT(*) FILTER (WHERE amount = 0)                                          AS zero_amount_transactions,
    ROUND(COUNT(*) FILTER (WHERE amount = 0) / COUNT(transaction_id)::numeric, 4) AS zero_amount_share
FROM fantasy.events;


-- 1.4. Популярные эпические предметы: доля продаж предмета и доля купивших его игроков
SELECT
    i.game_items,
    COUNT(e.transaction_id)                                                              AS total_items_sales,
    -- доля продаж предмета от всех платных продаж
    ROUND(COUNT(e.transaction_id)::numeric / SUM(COUNT(e.transaction_id)) OVER () * 100, 2) AS item_share_percent,
    -- доля игроков, купивших предмет хотя бы раз, от всех покупателей
    ROUND(COUNT(DISTINCT e.id)::numeric / (
        SELECT COUNT(DISTINCT id) FROM fantasy.events WHERE amount > 0
    ) * 100, 2)                                                                          AS buyers_share_percent
FROM fantasy.items AS i
LEFT JOIN fantasy.events AS e USING (item_code)
WHERE e.amount > 0
GROUP BY i.item_code, i.game_items
ORDER BY total_items_sales DESC;


/* ----------------------------------------------------------------------------
   Вспомогательные запросы для исследования аномалий (см. вывод 1.3)
---------------------------------------------------------------------------- */

-- Разброс цен на один и тот же предмет: одна и та же позиция продаётся
-- по разной стоимости (вероятно, из-за игровых условий или изменений цен)
SELECT
    i.game_items,
    COUNT(e.transaction_id) AS sales_count,
    e.amount
FROM fantasy.events AS e
LEFT JOIN fantasy.items AS i USING (item_code)
WHERE e.amount > 0
GROUP BY i.game_items, e.amount;

-- Покупки с крайне низкой ненулевой стоимостью (меньше 1)
SELECT COUNT(*) AS suspicious_low_price_count
FROM fantasy.events
WHERE amount > 0
  AND amount < 1;


/* ----------------------------------------------------------------------------
   Часть 2. Ad hoc-задача:
   зависимость активности игроков по покупкам от расы персонажа

   Логика:
     cte_events    — сразу собираем только ненулевые покупки, чтобы
                     дальнейшая фильтрация не отсекла нужные данные;
     cte_agr       — по каждой расе: всего игроков, покупателей, доля
                     покупателей и доля платящих среди покупателей;
     cte_avg_purch — средние метрики покупок на одного покупателя;
     финальный SELECT — объединяет обе группы метрик по расе.
---------------------------------------------------------------------------- */
WITH cte_events AS (
    SELECT *
    FROM fantasy.events
    WHERE amount > 0
),
cte_agr AS (
    SELECT
        r.race,
        COUNT(DISTINCT u.id)                                          AS total_users,
        COUNT(DISTINCT e.id)                                          AS total_buyers,
        ROUND(COUNT(DISTINCT e.id) / COUNT(DISTINCT u.id)::numeric * 100, 2) AS buyers_share_percent,
        COUNT(DISTINCT u.id) FILTER (WHERE u.payer = 1 AND e.id IS NOT NULL) AS total_paying_buyers,
        ROUND(
            COUNT(DISTINCT u.id) FILTER (WHERE u.payer = 1 AND e.id IS NOT NULL)::numeric
            / COUNT(DISTINCT e.id) * 100, 2
        )                                                             AS paying_buyers_share_percent
    FROM fantasy.users AS u
    LEFT JOIN fantasy.race AS r USING (race_id)
    LEFT JOIN cte_events AS e USING (id)
    GROUP BY r.race
),
cte_avg_purch AS (
    SELECT
        r.race,
        ROUND(COUNT(e.transaction_id)::numeric / COUNT(DISTINCT e.id), 1) AS avg_purchases_per_buyer,
        ROUND(AVG(e.amount)::numeric)                                     AS avg_amount_per_purchase,
        ROUND(SUM(e.amount)::numeric / COUNT(DISTINCT e.id), 1)           AS avg_total_amount_per_buyer
    FROM cte_events AS e
    LEFT JOIN fantasy.users AS u USING (id)
    LEFT JOIN fantasy.race  AS r USING (race_id)
    GROUP BY r.race
)
SELECT
    a.race,
    a.total_users,
    a.total_buyers,
    a.buyers_share_percent,
    a.total_paying_buyers,
    a.paying_buyers_share_percent,
    p.avg_purchases_per_buyer,
    p.avg_amount_per_purchase,
    p.avg_total_amount_per_buyer
FROM cte_agr AS a
LEFT JOIN cte_avg_purch AS p USING (race)
ORDER BY a.buyers_share_percent DESC;
