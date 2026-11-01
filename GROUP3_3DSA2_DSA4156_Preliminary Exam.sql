DROP SCHEMA IF EXISTS sakila_exam;
CREATE SCHEMA sakila_exam;
USE sakila_exam;

-- Build fact_rental_lifecycle
CREATE TABLE fact_rental_lifecycle (
	rental_id INT NOT NULL PRIMARY KEY,
    movie_key INT NOT NULL,
    customer_key INT NOT NULL,
    store_key INT NOT NULL,
    rented_date_key INT NOT NULL,
    returned_date_key INT,
    paid_date_key INT NOT NULL,
    allowed_days INT NOT NULL,
    days_out INT,
    days_late INT,
    is_returned TINYINT NOT NULL,
    is_late TINYINT,
	amount_paid DECIMAL(10, 2) NOT NULL,
    lifecycle_status ENUM('Open', 'Returned on time', 'Returned late') NOT NULL
);

INSERT INTO fact_rental_lifecycle
SELECT fr.rental_id, IFNULL(dm.movie_key, -1), IFNULL(dc.customer_key, -1),				-- rental_id, movie_key, customer_key
IFNULL(ds.store_key, -1), IFNULL(drend.date_key, -1), IFNULL(dretd.date_key, -1),		-- store_key, rented_date_key, returned_date_key,
IFNULL(dpayd.date_key, -1), dm.rental_days, DATEDIFF(sr.return_date, sr.rental_date),	-- paid_date_key, allowed_days, days_out,
0, 0, 0,																				-- days_late, is_returned, is_late; SET TEMPORARILY TO 0
sp.amount, 'Open'																		-- amount_paid, lifecycle_status; SET lifecycle_status TEMPORARILY TO 'Open'
FROM sakila_dw.fact_daily_rentals fr
LEFT JOIN sakila_dw.dim_movie dm ON dm.movie_key = fr.movie_key
LEFT JOIN sakila_dw.dim_customer dc ON dc.customer_key = fr.customer_key
LEFT JOIN sakila_dw.dim_store ds ON ds.store_key = dc.home_store_key
LEFT JOIN sakila_stg.rental sr ON sr.rental_id = fr.rental_id
LEFT JOIN sakila_dw.dim_date drend ON drend.date_key = fr.date_key
LEFT JOIN sakila_dw.dim_date dretd ON dretd.caldate = DATE(sr.return_date)
LEFT JOIN sakila_stg.payment sp ON sp.rental_id = fr.rental_id
LEFT JOIN sakila_dw.dim_date dpayd ON dpayd.caldate = DATE(sp.payment_date);

UPDATE fact_rental_lifecycle
SET
	days_late = CASE
		WHEN days_out IS NULL THEN NULL
        WHEN days_out > allowed_days THEN days_out - allowed_days
		ELSE 0 END,
        
	is_returned = CASE
		WHEN returned_date_key = -1 THEN 0
        ELSE 1 END,
	
	is_late = CASE
		WHEN days_late IS NULL THEN NULL
		WHEN days_late = 0 THEN 0
        ELSE 1 END,
        
	lifecycle_status = CASE
		WHEN is_late = 0 AND is_returned = 1 THEN 'Returned on time'
        WHEN is_late = 1 AND is_returned = 1 THEN 'Returned late'
        ELSE 'Open' END;

-- View fact_rental_lifecycle
SELECT * FROM fact_rental_lifecycle;

-- Report

-- (a) the row count, the number of returned and open rentals, and the number of rows with returned_date_key = -1
SELECT 'fact rows' AS chk, COUNT(*) AS number_of_rows FROM fact_rental_lifecycle -- 16044
UNION ALL SELECT CASE WHEN lifecycle_status IN ('Returned on time', 'Returned late') THEN 'Returned'
                      ELSE lifecycle_status END AS chk, COUNT(*) FROM fact_rental_lifecycle GROUP BY chk -- Returned = 15861; Open = 183;
UNION ALL SELECT 'returned_date_key = -1', COUNT(*) FROM fact_rental_lifecycle WHERE returned_date_key = -1; -- 183 (same as the number of 'Open' rows)

-- (b) the number of rentals in each lifecycle_status, and the total amount_paid

SELECT lifecycle_status, COUNT(*) AS number_of_rentals FROM fact_rental_lifecycle GROUP BY lifecycle_status; -- 'Returned on time' = 8592, 'Returned late' = 7269, 'Open' = 183
SELECT SUM(amount_paid) AS total_amount_paid FROM fact_rental_lifecycle; -- 67406.56

-- (c) a check that no row received -1 for movie, customer or store

SELECT 'movie_key = -1' AS chk, COUNT(*) AS number_of_rows FROM fact_rental_lifecycle WHERE movie_key = -1
UNION ALL SELECT 'customer_key = -1', COUNT(*) FROM fact_rental_lifecycle WHERE customer_key = -1
UNION ALL SELECT 'store_key = -1', COUNT(*) FROM fact_rental_lifecycle WHERE store_key = -1;

-- (d) two sentences on how this table differs from fact_daily_rentals: what each row represents over time, and how it is maintained

-- Each row of the fact table fact_rental_lifecycle represents a unique movie rental that a customer bought in a store, and it monitors whether a movie rental is returned on time, returned late, or open.
-- It also tracks how often a movie is being rented throughout its life cycle.

-- Q1

SELECT
	IF(GROUPING(store_name) = 1, 'ALL STORES', store_name) AS store_name,
	IF(GROUPING(YYYYMM) = 1, 'ALL MONTHS', YYYYMM) AS YYYYMM,
	IF(GROUPING(returned_or_open) = 1, 'ALL STATUSES', returned_or_open) AS returned_or_open,
	AVG(lifecycle_status = 'Returned late') * 100 AS 'returned_late_rate (%)',
	COUNT(*) AS number_of_rentals,
	SUM(amount_paid) AS revenue
FROM (
	SELECT
		ds.store_name,
        dd.YYYYMM,
        fr.lifecycle_status,
        CASE WHEN lifecycle_status IN ('Returned on time', 'Returned late') THEN 'Returned'
			 ELSE fr.lifecycle_status END AS returned_or_open,
        fr.amount_paid
	FROM fact_rental_lifecycle fr
    LEFT JOIN sakila_dw.dim_date dd ON dd.date_key = fr.rented_date_key
    LEFT JOIN sakila_dw.dim_store ds ON ds.store_key = fr.store_key) AS t
GROUP BY store_name, YYYYMM, returned_or_open WITH ROLLUP;

-- (a) the busiest month by rentals and by revenue, and each store's total revenue
	-- For both stores, July 2005 is the busiest month in terms of rentals and revenue.
	-- Store 1 (Lethbridge) earned 36,997.53  whereas Store 2 (Woodridge) earned 30,409.03.

-- (b) why the late-return percentage is empty for February 2006
-- The late-return percentage is empty or zero because the rentals have not yet been returned to the stores.

-- (c) one insight a store manager should take from the table
-- Store 2 has lower returned-late rates than Store 1 of all months.